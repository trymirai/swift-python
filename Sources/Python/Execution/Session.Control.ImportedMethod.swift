//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

// MARK: - ImportedCallRequest

protocol ImportedCallRequest: Object.Callable, Sendable {
    func cancel()
}

// MARK: - ImportedCall

final class ImportedCall<Result: Sendable>: Sendable {
    private typealias Continuation = CheckedContinuation<Result, any Swift::Error>

    private let receiver: Receiver
    private let name: String?

    private let arguments: [any Encodable & Sendable]
    private let keywords: [(String, any Encodable & Sendable)]

    private let decode: @Sendable (borrowing Object) throws -> Result

    private let state: Mutex<State> = .init(.initial)

    init(
        _ receiver: Receiver,
        name: String?,
        arguments: [any Encodable & Sendable],
        keywords: [(String, any Encodable & Sendable)],
        decode: @escaping @Sendable (borrowing Object) throws -> Result,
    ) {
        self.receiver = receiver
        self.name = name

        self.arguments = arguments
        self.keywords = keywords

        self.decode = decode
    }

    func value() async throws -> Result {
        let callback = try CurrentContext.callback()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                submit(continuation, to: callback)
            }
        } onCancel: {
            self.cancel()
            callback.wake()
        }
    }

    func value(in context: Context) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let outcome: Swift::Result<Result, any Swift::Error>
                do {
                    outcome = .success(try await withCheckedThrowingContinuation { continuation in
                        guard install(continuation) else {
                            return
                        }
                        group.addTask {
                            try await self.run(in: context)
                        }
                    })
                } catch {
                    outcome = .failure(error)
                }

                // Wait for Python's event loop to finish cleanup before propagating an error.
                try await group.waitForAll()
                return try outcome.get()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func run(in context: Context) async throws {
        do {
            try await context.withSessionContext { _ in
                unsafe try PThread.withCallbackAttachment { attachment in
                    try run(in: attachment)
                }
            }
        } catch {
            finish(.failure(error))
            throw error
        }
    }

    private func run(in attachment: borrowing PThread.Attachment) throws {
        guard let execution = attachment.storage.execution else {
            throw Session.Error.closed
        }

        let request = try Object.makeFunction(self, in: attachment)
        let functions = try Object.import(
            module: "_swift_python_runtime.exports.functions",
            in: attachment,
        )
        let control = try Object.makeFunction(
            Session.Control.Callback(
                execution: execution,
                streamsOutput: execution.hasOutputHandler,
            ),
            in: attachment,
        )
        let coroutine = try functions.attribute("call_imported").call(request, control)

        let block = try Object.import(
            module: "_swift_python_runtime.async_support",
            in: attachment,
        )
        .attribute("await_block")
        .call(coroutine, control)

        let run = try Object.import(module: "asyncio", in: attachment).attribute("run")
        unsafe try run.callInterruptibly([block.pointer], using: execution).decode(as: Void.self)
        // Let execution settlement handle failures after Python has finished cleaning up.
        if let error = state.withLock({ $0.error }) {
            throw error
        }
    }

    private func submit(_ continuation: Continuation, to callback: Session.Control.ExportCall) {
        guard install(continuation) else {
            return
        }

        do {
            try callback.submit(self)
        } catch {
            finish(.failure(error))
        }
    }

    private func install(_ continuation: Continuation) -> Bool {
        guard state.withLock({ $0.install(continuation) }) else {
            continuation.resume(throwing: CancellationError())
            return false
        }
        return true
    }

    private func finish(_ outcome: Swift::Result<Result, any Swift::Error>) {
        let error: (any Swift::Error)? = if case let .failure(error) = outcome {
            error
        } else {
            nil
        }
        let continuation = state.withLock { $0.finish(error) }
        continuation?.resume(with: outcome)
    }
}

// MARK: ImportedCall.Receiver

extension ImportedCall {
    enum Receiver: Sendable {
        case instance(Reference)
        case type(module: String, name: String)

        @_lifetime(borrow attachment)
        func object(in attachment: borrowing PThread.Attachment) throws -> Object {
            switch self {
            case let .instance(reference):
                try reference.object(in: attachment.storage.references, scopedTo: attachment)
            case let .type(module, name):
                try Object.importClass(module: module, name: name, in: attachment)
            }
        }
    }
}

// MARK: ImportedCall.State

extension ImportedCall {
    private enum State {
        case initial
        case waiting(Continuation)
        case finished((any Swift::Error)?)

        var error: (any Swift::Error)? {
            if case let .finished(error) = self {
                error
            } else {
                nil
            }
        }

        var isWaiting: Bool {
            if case .waiting = self {
                true
            } else {
                false
            }
        }

        mutating func install(_ continuation: Continuation) -> Bool {
            guard case .initial = self else {
                return false
            }
            self = .waiting(continuation)
            return true
        }

        mutating func finish(_ error: (any Swift::Error)?) -> Continuation? {
            if case .finished = self {
                return nil
            }
            // Cancellation can finish the request before the continuation is installed.
            let previous = exchange(&self, with: .finished(error))
            guard case let .waiting(continuation) = previous else {
                return nil
            }
            return continuation
        }
    }
}

// MARK: ImportedCallRequest

extension ImportedCall: ImportedCallRequest {
    func cancel() {
        finish(.failure(CancellationError()))
    }

    @_lifetime(borrow attachment)
    func call(
        _ request: borrowing Object,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        switch try request.item(at: 0).string() {
        case "pending":
            let pending = state.withLock { $0.isWaiting }
            return try Object(encoding: pending, in: attachment)
        case "call":
            return try invoke(in: attachment)
        case "return":
            finish(Swift::Result { try decode(request.item(at: 1)) })
        case "raise":
            try finish(raising: request.item(at: 1))
        case "cancel":
            cancel()
        default:
            throw Runtime.Failure("Unknown imported method callback command.")
        }

        return try Object(encoding: Value.none, in: attachment)
    }

    @_lifetime(borrow attachment)
    private func invoke(in attachment: borrowing PThread.Attachment) throws -> Object {
        guard state.withLock({ $0.isWaiting }) else {
            throw CancellationError()
        }

        let object = try receiver.object(in: attachment)
        let function = if let name {
            try object.attribute(name)
        } else {
            object.retained()
        }
        let value = try function.call(arguments: arguments, keywords: keywords)

        return unsafe _overrideLifetime(consume value, borrowing: attachment)
    }

    private func finish(raising error: borrowing Object) throws {
        let type = unsafe try Object.take(PyObject_Type(error.pointer), in: error)
        unsafe PyErr_SetObject(type.pointer, error.pointer)

        finish(.failure(Object.failure("An imported Python method failed.")))
    }
}

public extension Reference {
    /// Compiler support for an asynchronous imported instance method.
    @_documentation(visibility: internal)
    func _pAwaitMethod<Result: Sendable>(
        _ name: String,
        arguments: [any Encodable & Sendable],
        keywords: [(String, any Encodable & Sendable)],
        decode: @escaping @Sendable (borrowing Object) throws -> Result,
    ) async throws -> Result {
        try await ImportedCall(
            .instance(self),
            name: name,
            arguments: arguments,
            keywords: keywords,
            decode: decode,
        ).value()
    }
}

public extension _PImported {
    /// Compiler support for an asynchronous imported class method.
    @_documentation(visibility: internal)
    static func _pAwaitMethod<Result: Sendable>(
        _ name: String,
        arguments: [any Encodable & Sendable],
        keywords: [(String, any Encodable & Sendable)],
        decode: @escaping @Sendable (borrowing Object) throws -> Result,
    ) async throws -> Result {
        try await ImportedCall(
            .type(module: _pImport.module, name: _pImport.name),
            name: name,
            arguments: arguments,
            keywords: keywords,
            decode: decode,
        ).value()
    }
}

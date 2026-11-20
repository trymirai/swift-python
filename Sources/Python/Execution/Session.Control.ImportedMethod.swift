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
    private typealias Outcome = Swift::Result<Result, any Swift::Error>
    private typealias Continuation = CheckedContinuation<Void, Never>

    private let receiver: Receiver
    private let name: String?

    private let arguments: [any Encodable & Sendable]
    private let keywords: [(String, any Encodable & Sendable)]

    private let decode: @Sendable (borrowing Object) throws -> Result

    private let state: Mutex<State> = .init(.pending(nil))

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

    convenience init<Value: Decodable & Sendable & ~Copyable>(
        _ receiver: Receiver,
        arguments: [any Encodable & Sendable],
        keywords: [(String, any Encodable & Sendable)],
        as type: Value.Type,
    ) where Result == Session.Transfer<Value> {
        self.init(
            receiver,
            name: nil,
            arguments: arguments,
            keywords: keywords,
            decode: { try Session.Transfer($0.decode(as: type)) },
        )
    }

    func value(during callback: Session.Control.ExportCall) async throws -> Result {
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    submit(continuation, to: callback)
                }
            },
            onCancel: {
                self.cancel()
                callback.wake()
            },
        )
        return try takeResult()
    }

    func value(
        in session: Session?,
        from parent: Context? = nil,
        scope: (any Sendable)? = nil,
    ) async throws -> Result {
        try Task.checkCancellation()
        guard let session else {
            return try await value(during: CurrentContext.callback())
        }

        return try await session.withAttachment(
            generation: receiver.generation,
            in: parent,
            scope: scope,
        ) { try run(in: $0) }
    }

    private func run(in attachment: borrowing PThread.Attachment) throws -> Result {
        guard let execution = attachment.storage.execution else {
            throw Failure.closed
        }

        let request = try Object.makeFunction(self, in: attachment)
        let module = try Object.import(
            module: "_swift_python_runtime.async_support",
            in: attachment,
        )

        let control = try execution.makeCallback(
            streamsOutput: execution.hasOutputHandler,
            in: attachment,
        )
        let run = try module(methodNamed: "run_imported")
        let awaitResult = try Object(encoding: awaitsResult, in: attachment)

        do {
            _ = unsafe try run.callInterruptibly(
                [request.pointer, control.pointer, awaitResult.pointer],
                using: execution,
            )
        } catch {
            // The driver can exit before Python sends the terminal callback.
            _ = state.withLock { $0.take() }
            throw error
        }

        return try takeResult()
    }

    private var awaitsResult: Bool {
        // A constructor returns its instance even if the instance implements __await__.
        if case .type = receiver, name == nil {
            return false
        }
        return true
    }

    private func submit(_ continuation: Continuation, to callback: Session.Control.ExportCall) {
        guard state.withLock({ $0.install(continuation) }) else {
            continuation.resume()
            return
        }

        do {
            try callback.submit(self)
        } catch {
            finish(.failure(error))
        }
    }

    private func takeResult() throws -> Result {
        guard let outcome = state.withLock({ $0.take() }) else {
            throw Failure("The Python call finished without a result.")
        }
        return try outcome.get()
    }

    private func finish(_ outcome: Outcome) {
        let continuation = state.withLock { $0.finish(outcome) }
        continuation?.resume()
    }
}

// MARK: ImportedCall.Receiver

extension ImportedCall {
    enum Receiver: Sendable {
        case instance(Reference)
        case type(module: String, name: String)

        static func imported<Type: _PImported>(_ type: Type.Type) -> Self {
            .type(module: type._pImport.module, name: type._pImport.name)
        }

        var generation: Reference.Store? {
            switch self {
            case let .instance(reference):
                reference.storage.references
            case .type:
                nil
            }
        }

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
        // Only a call inside an active export needs a separate Swift waiter.
        case pending(Continuation?)
        case finished(Outcome?)

        var isPending: Bool {
            if case .pending = self {
                true
            } else {
                false
            }
        }

        mutating func install(_ continuation: Continuation) -> Bool {
            guard case .pending(nil) = self else {
                return false
            }
            self = .pending(continuation)
            return true
        }

        mutating func finish(_ outcome: Outcome) -> Continuation? {
            guard case let .pending(continuation) = self else {
                return nil
            }
            self = .finished(outcome)
            return continuation
        }

        mutating func take() -> Outcome? {
            guard case let .finished(outcome) = exchange(&self, with: .finished(nil)) else {
                return nil
            }
            return outcome
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
        switch try request.tupleItem(at: 0).string() {
        case "pending":
            let pending = state.withLock { $0.isPending }
            return try Object(encoding: pending, in: attachment)
        case "call":
            do {
                return try invoke(in: attachment)
            } catch {
                // Re-raising a Swift error in Python can only reconstruct built-in exceptions.
                finish(.failure(error))
                throw error
            }
        case "return":
            finish(Swift::Result { try decode(request.tupleItem(at: 1)) })
        case "raise":
            try finish(raising: request.tupleItem(at: 1))
        case "cancel":
            cancel()
        default:
            throw Failure("Unknown imported method callback command.")
        }

        return try Object(encoding: Value.none, in: attachment)
    }

    @_lifetime(borrow attachment)
    private func invoke(in attachment: borrowing PThread.Attachment) throws -> Object {
        guard state.withLock({ $0.isPending }) else {
            throw CancellationError()
        }

        let object = try receiver.object(in: attachment)
        let function = if let name {
            try object(methodNamed: name)
        } else {
            consume object
        }
        let value = try function(arguments: arguments, keywords: keywords)

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
        let call = ImportedCall(
            .instance(self),
            name: name,
            arguments: arguments,
            keywords: keywords,
            decode: decode,
        )
        if let callback = try CurrentContext.activeExport() {
            return try await call.value(during: callback)
        }
        guard let owner = storage.references.session else {
            throw Failure.closed
        }
        return try await call.value(in: owner)
    }
}

public extension _PImported {
    /// Compiler support for an asynchronous imported class method.
    @_documentation(visibility: internal)
    static func _pAwaitMethod<Result: Sendable>(
        _ name: String,
        arguments: [any Encodable & Sendable],
        keywords: [(String, any Encodable & Sendable)],
        in session: Session? = nil,
        from parent: Context? = nil,
        scope: (any Sendable)? = nil,
        decode: @escaping @Sendable (borrowing Object) throws -> Result,
    ) async throws -> Result {
        let call = ImportedCall(
            .imported(Self.self),
            name: name,
            arguments: arguments,
            keywords: keywords,
            decode: decode,
        )
        return try await call.value(in: session, from: parent, scope: scope)
    }
}

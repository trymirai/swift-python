//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

// MARK: - ImportedMethodRequest

protocol ImportedMethodRequest: Object.Callable, Sendable {
    func cancel()
}

// MARK: - ImportedMethod

private final class ImportedMethod<Result: Sendable> {
    private typealias Continuation = CheckedContinuation<Result, any Swift::Error>

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

    private enum State {
        case initial
        case waiting(Continuation)
        case finished

        var isWaiting: Bool {
            if case .waiting = self {
                true
            } else {
                false
            }
        }
    }

    private let receiver: Receiver
    private let name: String

    private let arguments: [any Encodable & Sendable]
    private let keywords: [(String, any Encodable & Sendable)]

    private let decode: @Sendable (borrowing Object) throws -> Result
    private let state: Mutex<State> = .init(.initial)

    init(
        _ receiver: Receiver,
        name: String,
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
        guard let callback = Session.Control.currentExport else {
            throw Runtime.Failure("An async Python method requires an active Swift export.")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                submit(continuation, to: callback)
            }
        } onCancel: {
            self.cancel()
            callback.wake()
        }
    }

    private func submit(_ continuation: Continuation, to callback: Session.Control.ExportCall) {
        let installed = state.withLock { state in
            guard case .initial = state else {
                return false
            }
            state = .waiting(continuation)
            return true
        }
        guard installed else {
            continuation.resume(throwing: CancellationError())
            return
        }

        do {
            try callback.submit(self)
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ outcome: Swift::Result<Result, any Swift::Error>) {
        let continuation = state.withLock { state -> Continuation? in
            // Cancellation can finish the request before the continuation is installed.
            let previous = exchange(&state, with: .finished)
            guard case let .waiting(continuation) = previous else {
                return nil
            }
            return continuation
        }
        continuation?.resume(with: outcome)
    }
}

// MARK: ImportedMethodRequest

extension ImportedMethod: ImportedMethodRequest {
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
        let method = try object.attribute(name)
        let value = try method.call(arguments: arguments, keywords: keywords)

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
        try await ImportedMethod(
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
        try await ImportedMethod(
            .type(module: _pImport.module, name: _pImport.name),
            name: name,
            arguments: arguments,
            keywords: keywords,
            decode: decode,
        ).value()
    }
}

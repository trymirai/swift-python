//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - PThread

// Owns a detached subinterpreter. Create and destroy it on its executor.
@safe
struct PThread: ~Copyable {
    private let pointer: UnsafeMutablePointer<PyThreadState>

    let storage: Interpreter.Storage

    init(
        fileAccess: Interpreter.FileAccess? = nil,
        session: Session? = nil,
        scheduleRelease: @escaping @Sendable () -> Void = {},
    ) throws {
        var pointer: UnsafeMutablePointer<PyThreadState>?
        let status = unsafe CPython_NewThreadState(&pointer)
        guard unsafe PyStatus_Exception(status) == 0, let pointer = unsafe pointer else {
            throw unsafe Self.failure(status, default: "Unable to create a Python interpreter.")
        }

        let storage: Interpreter.Storage
        do {
            let view = unsafe try Interpreter.View(state: pointer)
            storage = unsafe Interpreter.Storage(
                key: CPython_InterpreterKey(pointer),
                view: view,
                session: session,
                fileAccess: fileAccess,
                schedule: scheduleRelease,
            )
        } catch {
            unsafe CPython_EndThreadState(pointer)
            throw error
        }

        unsafe self.pointer = pointer
        self.storage = storage
    }

    deinit {
        storage.withFileAccess {
            unsafe CPython_AttachThreadState(pointer)
            storage.close()
            CPython_DetachThreadState()
            unsafe CPython_EndThreadState(pointer)
        }
        storage.unregister()
    }

    static func initializeRuntime() throws {
        let status = unsafe CPython_InitializeRuntime()
        if unsafe PyStatus_Exception(status) != 0 {
            throw unsafe failure(status, default: "Unable to initialize Python.")
        }
    }

    borrowing func withAttached<Result: Sendable & ~Copyable>(
        _ body: (borrowing Attachment) throws -> Result,
    ) rethrows -> Result {
        try withScope(execution: nil) { _ in try withCurrentAttachment(body) }
    }

    borrowing func withAttached<Result: Sendable & ~Copyable>(
        execution: Session.Control,
        _ body: (borrowing Attachment) throws -> Result,
    ) throws -> Result {
        try withScope(execution: execution) { scope in
            try scope.withEvaluation { try withCurrentAttachment(body) }
        }
    }

    private borrowing func withCurrentAttachment<Result: ~Copyable>(
        _ body: (borrowing Attachment) throws -> Result,
    ) rethrows -> Result {
        storage.releasePendingReferences()
        return try Self.withAttachment(to: storage, body)
    }

    private borrowing func withScope<Result: ~Copyable>(
        execution: Session.Control?,
        _ body: (Scope) throws -> Result,
    ) rethrows -> Result {
        precondition(unsafe PyThreadState_GetUnchecked() == nil)
        unsafe CPython_AttachThreadState(pointer)
        defer { CPython_DetachThreadState() }

        return try Scope.run(storage: storage, execution: execution) { scope in
            try storage.withFileAccess {
                try body(scope)
            }
        }
    }

    // CPython enters Swift callbacks with the originating state already attached.
    // This scope borrows that attachment without releasing it on return.
    @unsafe
    static func withCallbackAttachment<Result>(
        _ body: (borrowing Attachment) throws -> Result,
    ) throws -> Result {
        let storage = try Interpreter.Storage.requireCurrent()
        return try withAttachment(to: storage, body)
    }

    private static func withAttachment<Result: ~Copyable>(
        to storage: Interpreter.Storage,
        _ body: (borrowing Attachment) throws -> Result,
    ) rethrows -> Result {
        try storage.withConstructionScope { try body(Attachment(storage)) }
    }

    private static func failure(_ status: borrowing PyStatus, default fallback: String) -> Failure {
        guard let message = unsafe status.err_msg else {
            return Failure(fallback)
        }
        return Failure(unsafe String(cString: message))
    }
}

// MARK: PThread.Attachment

extension PThread {
    struct Attachment: ~Copyable, ~Escapable {
        let storage: Interpreter.Storage

        @_lifetime(borrow storage)
        fileprivate init(_ storage: borrowing Interpreter.Storage) {
            self.storage = copy storage
        }
    }
}

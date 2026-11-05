//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - ThreadState

// Owns a detached subinterpreter. Create and destroy it on its executor.
@safe
struct ThreadState: ~Copyable {
    private let pointer: UnsafeMutablePointer<PyThreadState>
    let storage: InterpreterStorage

    init(scheduleRelease: @escaping @Sendable () -> Void = {}) throws {
        var pointer: UnsafeMutablePointer<PyThreadState>?
        let status = unsafe CPython_NewThreadState(&pointer)
        guard unsafe PyStatus_Exception(status) == 0, let pointer = unsafe pointer else {
            throw RuntimeFailure(unsafe Self.message(
                status,
                default: "Unable to create a Python interpreter.",
            ))
        }
        unsafe self.pointer = pointer
        self.storage = InterpreterStorage(
            key: unsafe CPython_InterpreterKey(pointer),
            schedule: scheduleRelease,
        )
    }

    deinit {
        unsafe PyEval_RestoreThread(pointer)
        storage.close()
        _ = unsafe PyEval_SaveThread()
        unsafe CPython_EndThreadState(pointer)
        storage.unregister()
    }

    static func initialize() throws {
        let status = unsafe CPython_InitializeRuntime()
        if unsafe PyStatus_Exception(status) != 0 {
            throw RuntimeFailure(unsafe message(
                status,
                default: "Unable to initialize Python.",
            ))
        }
    }

    borrowing func withAttached<Result: Sendable & ~Copyable>(
        _ body: (borrowing Attachment) throws -> Result,
    ) rethrows -> Result {
        precondition(unsafe PyThreadState_GetUnchecked() == nil)
        unsafe PyEval_RestoreThread(pointer)
        storage.releasePendingReferences()
        defer {
            storage.releasePendingReferences()
            _ = unsafe PyEval_SaveThread()
        }
        return try body(Attachment())
    }

    // CPython enters Swift callbacks with the originating state already attached.
    // This scope borrows that attachment without releasing it on return.
    @unsafe
    static func withCurrent<Result>(
        _ body: (borrowing Attachment) throws -> Result,
    ) rethrows -> Result {
        precondition(unsafe PyThreadState_GetUnchecked() != nil)
        defer {
            InterpreterStorage.current()?.releasePendingReferences()
        }
        return try body(Attachment())
    }

    private static func message(_ status: borrowing PyStatus, default fallback: String) -> String {
        guard let message = unsafe status.err_msg else {
            return fallback
        }
        return unsafe String(cString: message)
    }
}

// MARK: ThreadState.Attachment

extension ThreadState {
    struct Attachment: ~Copyable {
        fileprivate init() {}
    }
}

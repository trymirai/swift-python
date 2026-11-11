//
//  Created by Anton Spivak
//

// MARK: - CurrentContext

enum CurrentContext {
    // IMPORTANT: This is the ONLY task-local value in the Python bridge.
    // Its sole purpose is direct access to Python-backed properties and imported
    // methods during a Swift export, including after await. Do not use or extend
    // it for session selection, reentrancy, configuration, or any other implicit
    // dependency. Those dependencies must be passed explicitly.
    // It holds no raw Python object or attached thread state. The callback must
    // still be active, and each synchronous access attaches and detaches Python.
    @TaskLocal
    private static var current: Session.Control.ExportCall?

    static func withExport(
        _ callback: Session.Control.ExportCall?,
        _ body: () async -> Void,
    ) async {
        await $current.withValue(callback, operation: body)
    }

    static func withAttached<Result: ~Copyable>(
        _ body: () throws -> Result,
    ) rethrows -> Result {
        // A synchronous callback or enqueue block uses its own attachment.
        // Tasks escaping that block must not inherit an outer async export.
        var result: Result?
        try $current.withValue(nil) { result = try body() }
        return result!
    }

    static func run<Result: ~Copyable>(
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        if let storage = Interpreter.Storage.current(), PThread.Scope.current?.matchesTask == true {
            _ = try Interpreter.Storage.requireCurrent()
            return try body(Context(storage: storage))
        }
        return try callback().withContext(body)
    }

    static func callback() throws -> Session.Control.ExportCall {
        guard let current else {
            throw Session.Error.closed
        }
        try current.checkActive()
        return current
    }
}

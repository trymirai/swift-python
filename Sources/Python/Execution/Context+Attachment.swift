//
//  Created by Anton Spivak
//

internal import libcpython

extension Context {
    func withAccess<Result: ~Copyable>(
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        if PThread.Scope.current?.matchesTask == true {
            try checkAccess()
            return try body(self)
        }

        try invocation?.checkActive()
        guard let execution else {
            throw Failure.closed
        }

        return try execution.withAccess {
            let streams = self.streams
            defer { withExtendedLifetime(streams) {} }
            return try withAttached(execution: execution, streams: streams, body)
        }
    }

    private func withAttached<Result: ~Copyable>(
        execution: Session.Control,
        streams: Session.Stream.Descriptors?,
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        try Task.checkCancellation()
        return unsafe try references.view.withStorage { storage, guardPointer in
            try storage.references.requireSameGeneration(as: references)

            return try PThread.Scope.run(
                storage: storage,
                execution: execution,
                streams: streams,
            ) { scope in
                scope.invocation = invocation
                return unsafe try withThreadState(in: storage, guardedBy: guardPointer) {
                    try withAttachedContext(in: scope, body)
                }
            }
        }
    }

    private func withAttachedContext<Result: ~Copyable>(
        in scope: PThread.Scope,
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        try scope.withEvaluation(inheritingOperation: true) {
            _ = try Interpreter.Storage.requireCurrent()
            try Task.checkCancellation()
            return try scope.storage.withConstructionScope {
                try body(Context(storage: scope.storage))
            }
        }
    }

    @unsafe
    private func withThreadState<Result: ~Copyable>(
        in storage: Interpreter.Storage,
        guardedBy guardPointer: OpaquePointer,
        _ body: () throws -> Result,
    ) throws -> Result {
        try storage.withFileAccess {
            guard let token = unsafe PyThreadState_Ensure(guardPointer) else {
                throw Failure("Unable to attach to the Python interpreter.")
            }
            defer { unsafe PyThreadState_Release(token) }
            return try body()
        }
    }
}

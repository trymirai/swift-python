//
//  Created by Anton Spivak
//

public extension Session {
    /// Runs synchronously on this session's interpreter thread in the operation queue.
    /// Scoped Python objects and views cannot escape the closure or cross an await.
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        in context: Context? = nil,
        scope: (any Sendable)? = nil,
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        try await enqueue(generation: nil, in: context, scope: scope, body)
    }
}

extension Session {
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        generation: Reference.Store?,
        in context: Context? = nil,
        scope: (any Sendable)? = nil,
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        let result = try await withAttachment(generation: generation, in: context, scope: scope) {
            Session.Transfer(try body(Context(storage: $0.storage)))
        }
        return result.take()
    }

    nonisolated func withAttachment<Result: Sendable>(
        generation: Reference.Store?,
        in parent: Context?,
        scope: (any Sendable)?,
        _ body: @Sendable (borrowing PThread.Attachment) throws -> Result,
    ) async throws -> Result {
        try await withExecution(in: parent, scope: scope) { session, execution in
            try session
                .withInterpreter(execution: execution, generation: generation) { interpreter in
                    try interpreter.pThread.withAttached(execution: execution) { attachment in
                        try CurrentContext.withAttached { try body(attachment) }
                    }
                }
        }
    }
}

//
//  Created by Anton Spivak
//

public import SystemPackage

public extension Session {
    /// Evaluates an interactive block with top-level await.
    ///
    /// Blocks and package operations share a queue. The timeout starts when the block
    /// runs and includes implicit startup. Interrupted blocks wait for Swift callbacks
    /// to finish before returning.
    ///
    /// Output redirections append to absolute paths for this block. Implicit startup
    /// captures its own output.
    ///
    /// The scope is available to Swift exports and the file access delegate during the block.
    nonisolated func evaluate(
        _ source: String,
        scope: (any Sendable)? = nil,
        filename: String? = nil,
        timeout: Duration? = nil,
        redirecting redirects: [Stream: FilePath] = [:],
        _ output: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Execution {
        try await run(
            .interactive(source),
            scope: scope,
            filename: filename,
            timeout: timeout,
            redirecting: redirects,
            output: output,
        )
    }

    /// Runs startup when the session is idle. The redirections apply to startup.
    nonisolated func initialize(
        scope: (any Sendable)? = nil,
        redirecting redirects: [Stream: FilePath] = [:],
    ) async throws {
        try await withExecution(scope: scope) { session, execution in
            let redirects = try redirects.mapValues(Runtime.Path.init)
            try session.openInterpreterIfNeeded(execution: execution, redirecting: redirects)
        }
    }

    /// Calls the host after a transactional block and its Swift callbacks finish.
    /// Call `Commit.seal()` immediately before publishing external changes.
    /// If publication fails after sealing, restore those changes before throwing.
    nonisolated func evaluate(
        _ source: String,
        scope: (any Sendable)? = nil,
        filename: String? = nil,
        timeout: Duration? = nil,
        redirecting redirects: [Stream: FilePath] = [:],
        committing: @escaping @Sendable (Commit) async throws -> Void,
        output: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Execution {
        try await run(
            .interactive(source),
            scope: scope,
            filename: filename,
            timeout: timeout,
            redirecting: redirects,
            output: output,
            committing: committing,
        )
    }

    struct Commit: Sendable {
        let checking: @Sendable () throws -> Void

        /// Seals the execution for publication. Throws if it was stopped or timed out.
        public func seal() throws {
            try checking()
        }
    }

    /// Runs synchronously on this session's interpreter thread in the operation queue.
    /// Scoped Python objects and views cannot escape the closure or cross an await.
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        scope: (any Sendable)? = nil,
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        try await enqueue(in: nil, scope: scope, body)
    }

    /// Runs asynchronous Swift work with a context bound to the current generation.
    /// Each asynchronous context operation takes its own turn in the session queue.
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Context) async throws -> R,
    ) async throws -> R {
        let context = try await enqueue { $0 }
        return try await body(context)
    }
}

extension Session {
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        in generation: Reference.Store?,
        scope: (any Sendable)? = nil,
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        let result = try await withExecution(scope: scope) { session, execution in
            try session
                .withInterpreter(execution: execution, generation: generation) { interpreter in
                    Session.Transfer(try interpreter.withContext(body, execution: execution))
                }
        }
        return result.take()
    }

    nonisolated func run(
        _ source: Interpreter.Source,
        scope: (any Sendable)?,
        filename: String?,
        timeout: Duration?,
        redirecting redirects: [Stream: FilePath],
        output: Control.OutputHandler?,
        committing: (@Sendable (Commit) async throws -> Void)? = nil,
    ) async throws -> Execution {
        guard committing == nil || transactional else {
            throw Runtime.Failure("A host commit requires a transactional Python session.")
        }

        let settlement = transactional ? Self.checkpointSettlement(committing: committing) : nil
        return try await withExecution(
            timeout: timeout,
            scope: scope,
            output: output,
            onInterruption: Self.interruptedExecution,
            settling: settlement,
        ) { session, execution in
            let redirects = try redirects.mapValues(Runtime.Path.init)
            return try session.withInterpreter(execution: execution) { interpreter in
                if session.transactional {
                    try interpreter.beginCheckpoint()
                }
                let captured = try interpreter.evaluate(
                    source,
                    filename: filename,
                    redirecting: redirects,
                    execution: execution,
                )
                return Execution(output: captured, end: .finished)
            }
        }
    }
}

// MARK: - Execution outcome

private extension Session {
    @Sendable
    static func interruptedExecution(
        _ interruption: Control.Interruption,
        _ result: Swift::Result<Execution, any Swift::Error>,
    ) -> Execution {
        let captured: Output = switch result {
        case let .success(execution):
            execution.output
        case let .failure(error as ExecutionError):
            error.output
        case .failure:
            .empty
        }
        let end: Execution.End = switch interruption {
        case .stopped:
            .stopped
        case .timedOut:
            .timedOut
        }
        return Execution(output: captured, end: end)
    }

    static func checkpointSettlement(
        committing: (@Sendable (Commit) async throws -> Void)?,
    ) -> Control.Settlement<Execution> {
        { session, control, result in
            do {
                _ = try result.get()
                try control.checkInterruption()

                if let committing {
                    let commit = Commit(checking: control.finishCheckingInterruption)
                    let path = Control.sessionPath + [session.origin]
                    try await Control.$sessionPath.withValue(path) {
                        try await committing(commit)
                    }
                }

                try control.finishCheckingInterruption()
                session.finishCheckpoint(.commit)
                return result
            } catch {
                session.finishCheckpoint(.rollback)
                return control.interruption == nil ? .failure(error) : result
            }
        }
    }
}

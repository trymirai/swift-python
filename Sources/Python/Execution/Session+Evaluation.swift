//
//  Created by Anton Spivak
//

public import SystemPackage

public extension Session {
    /// Evaluates a complete interactive execution, including top-level await.
    /// Blocks and package operations share a FIFO queue, including time spent
    /// awaiting dependency preparation. A deadline starts when the execution runs.
    /// An interrupted execution waits for its Swift callbacks before returning its outcome.
    /// Redirections use absolute paths. Execution appends to redirected output files.
    nonisolated func evaluate(
        _ source: String,
        filename: String? = nil,
        timeout: Duration? = nil,
        redirecting redirects: [Stream: FilePath] = [:],
        _ output: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Execution {
        try await run(
            .interactive(source),
            filename: filename,
            timeout: timeout,
            redirecting: redirects,
            output: output,
        )
    }

    /// Runs synchronously on this session's interpreter thread in the operation queue.
    /// Scoped Python objects and views cannot escape the closure or cross an await.
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        try await enqueue(in: nil, body)
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
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        let result = try await withExecution { session, execution in
            try session
                .withInterpreter(execution: execution, generation: generation) { interpreter in
                    Session.Transfer(try interpreter.withContext(body, execution: execution))
                }
        }
        return result.take()
    }

    func prepare(redirecting redirects: [Stream: FilePath] = [:]) async throws {
        if environment?.needsPreparation == true {
            _ = try await packages.resolve()
        }
        try await withExecution(redirecting: redirects) { session, execution in
            try session.withInterpreter(execution: execution) { _ in }
        }
    }

    nonisolated func run(
        _ source: Interpreter.Source,
        filename: String?,
        timeout: Duration?,
        redirecting redirects: [Stream: FilePath],
        output: Control.OutputHandler?,
    ) async throws -> Execution {
        @Sendable
        func interrupted(
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

        return try await withExecution(
            timeout: timeout,
            redirecting: redirects,
            output: output,
            onInterruption: interrupted,
        ) { session, execution in
            try session.withInterpreter(execution: execution) { interpreter in
                let captured = try interpreter.evaluate(
                    source,
                    filename: filename,
                    execution: execution,
                )
                return Execution(output: captured, end: .finished)
            }
        }
    }
}

//
//  Created by Anton Spivak
//

public extension Session {
    /// Evaluates a complete interactive execution, including top-level await.
    /// Blocks and package operations share a FIFO queue, including time spent
    /// awaiting dependency preparation. A deadline starts when the execution runs.
    nonisolated func evaluate(
        _ source: String,
        filename: String? = nil,
        timeout: Duration? = nil,
        standardIO: StandardIO = .init(),
        onOutput: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Output {
        try await run(
            .interactive(source),
            filename: filename,
            timeout: timeout,
            standardIO: standardIO,
            onOutput: onOutput,
        )
    }

    /// Runs synchronously on this session's interpreter thread in the operation queue.
    /// Scoped Python objects and views cannot escape the closure or cross an await.
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        let result = try await withExecution { session, execution in
            let value = try session.withInterpreter(execution: execution) { interpreter in
                try interpreter.withContext(body, execution: execution)
            }
            try execution.checkInterruption()
            return ValueTransfer(value)
        }
        return result.take()
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
    func prepare(standardIO: StandardIO = .init()) async throws {
        try await resolvePackages()
        _ = try await run(nil, filename: nil, timeout: nil, standardIO: standardIO, onOutput: nil)
    }

    nonisolated func run(
        _ source: Interpreter.Source?,
        filename: String?,
        timeout: Duration?,
        standardIO: StandardIO,
        onOutput: ExecutionControl.OutputHandler?,
    ) async throws -> Output {
        try await withExecution(timeout: timeout, standardIO: standardIO, onOutput: onOutput) {
            session, execution in
            try session.evaluate(source, filename: filename, execution: execution)
        }
    }

    private func evaluate(
        _ source: Interpreter.Source?,
        filename: String?,
        execution: ExecutionControl,
    ) throws -> Output {
        let timer = execution.startTimeoutTask()
        defer { timer?.cancel() }
        let result = Result {
            try withInterpreter(execution: execution) { interpreter in
                guard let source else {
                    return startupOutput ?? .empty
                }
                return try interpreter.evaluate(source, filename: filename, execution: execution)
            }
        }
        guard let interruption = execution.finish() else {
            return try result.get()
        }

        switch result {
        case let .success(output):
            throw interruption.error(with: output)
        case let .failure(error):
            if case let .exception(_, output)? = error as? ExecutionError {
                throw interruption.error(with: output)
            }
            throw interruption.error()
        }
    }
}

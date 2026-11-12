//
//  Created by Anton Spivak
//

import Synchronization
public import SystemPackage

public extension Session {
    /// Evaluates an interactive block with top-level await.
    ///
    /// Blocks and package operations share a queue. The timeout starts when the block
    /// runs and includes implicit startup. Interrupted blocks wait for Swift callbacks
    /// to finish before returning. Cancel the calling task to interrupt the execution.
    ///
    /// Standard output and error redirections append to absolute paths for this block.
    /// A source redirection saves recorded input to a new file. Implicit startup captures
    /// its own output.
    /// Set recordingHistory to false to exclude an internal block from In/Out and numbering.
    /// An explicit reservation supplies the history number and requires recordingHistory.
    /// It is consumed before queue admission, including when that wait is cancelled.
    ///
    /// The scope is available to Swift exports and the file access delegate during the block.
    nonisolated func evaluate(
        _ source: String,
        scope: (any Sendable)? = nil,
        filename: String? = nil,
        timeout: Duration? = nil,
        recordingHistory: Bool = true,
        reservation: Reservation? = nil,
        redirecting redirects: [Stream: FilePath] = [:],
        in context: Context? = nil,
        _ output: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Execution {
        try await run(
            .interactive(source),
            in: context,
            scope: scope,
            filename: filename,
            timeout: timeout,
            recordingHistory: recordingHistory,
            reservation: reservation,
            redirecting: redirects,
            output: output,
        )
    }

    /// Calls the host after a successful block and its Swift callbacks finish.
    /// Call `Commit.seal()` immediately before publishing external changes.
    /// If publication fails after sealing, restore those changes before throwing.
    nonisolated func evaluate(
        _ source: String,
        scope: (any Sendable)? = nil,
        filename: String? = nil,
        timeout: Duration? = nil,
        recordingHistory: Bool = true,
        reservation: Reservation? = nil,
        redirecting redirects: [Stream: FilePath] = [:],
        in context: Context? = nil,
        committing: @escaping @Sendable (Commit) async throws -> Void,
        output: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Execution {
        try await run(
            .interactive(source),
            in: context,
            scope: scope,
            filename: filename,
            timeout: timeout,
            recordingHistory: recordingHistory,
            reservation: reservation,
            redirecting: redirects,
            output: output,
            committing: committing,
        )
    }

    struct Commit: Sendable {
        let checking: @Sendable () throws -> Void

        /// Seals the execution for publication. Throws if it was cancelled or timed out.
        public func seal() throws {
            try checking()
        }
    }

    /// Runs startup when the session is idle. The redirections apply to startup.
    nonisolated func initialize(
        scope: (any Sendable)? = nil,
        redirecting redirects: [Stream: FilePath] = [:],
        in context: Context? = nil,
    ) async throws {
        try await withExecution(in: context, scope: scope) { session, execution in
            let redirects = try redirects.mapValues(Runtime.Path.init)
            try session.openInterpreterIfNeeded(execution: execution, redirecting: redirects)
        }
    }

    /// Runs synchronously on this session's interpreter thread in the operation queue.
    /// Scoped Python objects and views cannot escape the closure or cross an await.
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        in context: Context? = nil,
        scope: (any Sendable)? = nil,
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        try await enqueue(generation: nil, in: context, scope: scope, body)
    }

    /// Runs asynchronous Swift work with a context bound to the current generation.
    /// Each asynchronous context operation takes its own turn in the session queue.
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        in parent: Context? = nil,
        _ body: @Sendable (borrowing Context) async throws -> R,
    ) async throws -> R {
        let context = try await enqueue(in: parent) { $0 }
        return try await body(context)
    }
}

extension Session {
    nonisolated func enqueue<R: Sendable & ~Copyable>(
        generation: Reference.Store?,
        in context: Context? = nil,
        scope: (any Sendable)? = nil,
        _ body: @Sendable (borrowing Context) throws -> R,
    ) async throws -> R {
        let result = try await withExecution(in: context, scope: scope) { session, execution in
            try session
                .withInterpreter(execution: execution, generation: generation) { interpreter in
                    Session.Transfer(try interpreter.withContext(body, execution: execution))
                }
        }
        return result.take()
    }

    nonisolated func run(
        _ source: Interpreter.Source,
        in context: Context? = nil,
        scope: (any Sendable)?,
        filename: String?,
        timeout: Duration?,
        recordingHistory: Bool = true,
        reservation: Reservation? = nil,
        redirecting redirects: [Stream: FilePath],
        output: Control.OutputHandler?,
        committing: (@Sendable (Commit) async throws -> Void)? = nil,
    ) async throws -> Execution {
        let reservedNumber = try claim(reservation, for: source, recordingHistory: recordingHistory)

        let settlement = committing.map(Self.publicationSettlement)
        let number = Mutex<Int?>(reservedNumber)
        return try await withExecution(
            in: context,
            timeout: timeout,
            scope: scope,
            output: output,
            onInterruption: { interruption, result in
                Self.interruptedExecution(interruption, result, number: number.withLock { $0 })
            },
            settling: settlement,
        ) { session, execution in
            let redirects = try redirects.mapValues(Runtime.Path.init)
            try await session.recordInput(
                source,
                enabled: recordingHistory,
                redirecting: redirects,
                number: number,
            )
            return try session.evaluate(
                source,
                filename: filename,
                number: number.withLock { $0 },
                redirecting: redirects,
                execution: execution,
            )
        }
    }

    private nonisolated func claim(
        _ reservation: Reservation?,
        for source: Interpreter.Source,
        recordingHistory: Bool,
    ) throws -> Int? {
        guard let reservation else {
            return nil
        }
        guard recordingHistory, case .interactive = source, let history else {
            throw Runtime.Failure("A reservation requires recorded interactive input.")
        }
        return try reservation.claim(in: history)
    }

    private func evaluate(
        _ source: Interpreter.Source,
        filename: String?,
        number: Int?,
        redirecting redirects: [Stream: Runtime.Path],
        execution: Control,
    ) throws -> Execution {
        do {
            return try withInterpreter(execution: execution) { interpreter in
                let captured = try interpreter.evaluate(
                    source,
                    filename: filename,
                    number: number,
                    redirecting: redirects,
                    execution: execution,
                )
                return Execution(output: captured, end: .finished, number: number)
            }
        } catch let error as ExecutionError {
            throw ExecutionError(traceback: error.traceback, output: error.output, number: number)
        }
    }

    private func recordInput(
        _ source: Interpreter.Source,
        enabled: Bool,
        redirecting redirects: [Stream: Runtime.Path],
        number: borrowing Mutex<Int?>,
    ) async throws {
        guard enabled, case let .interactive(source) = source, let history else {
            return
        }

        let destination = redirects[.source]
        try Self.validateSourceDestination(in: redirects)

        let reserved = number.withLock { $0 }
        let next = try reserved ?? history.reserveNumber()
        // Interruption must report the reserved number even if saving the source fails.
        number.withLock { $0 = next }
        try await history.save(source, number: next, destination: destination)
    }

    private static func validateSourceDestination(in redirects: [Stream: Runtime.Path]) throws {
        guard let destination = redirects[.source] else {
            return
        }
        let sourcePath = destination.file.lexicallyNormalized()
        let hasConflictingRedirect = redirects.contains { stream, path in
            stream != .source && path.file.lexicallyNormalized() == sourcePath
        }
        if hasConflictingRedirect {
            throw Runtime.Failure("A source history file must be separate from standard streams.")
        }
    }
}

// MARK: - Execution outcome

private extension Session {
    @Sendable
    static func interruptedExecution(
        _ interruption: Control.Interruption,
        _ result: Swift::Result<Execution, any Swift::Error>,
        number: Int?,
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
        return Execution(output: captured, end: end, number: number)
    }

    static func publicationSettlement(
        committing: @escaping @Sendable (Commit) async throws -> Void,
    ) -> Control.Settlement<Execution> {
        { _, control, result in
            do {
                _ = try result.get()
                try control.checkInterruption()

                let commit = Commit(checking: control.finishCheckingInterruption)
                try await committing(commit)
                try control.finishCheckingInterruption()
                return result
            } catch {
                return control.interruption == nil ? .failure(error) : result
            }
        }
    }
}

//
//  Created by Anton Spivak
//

import Synchronization
public import SystemPackage

public extension Session {
    /// Evaluates an interactive block with top-level await.
    ///
    /// Blocks and package operations share a queue. Interrupted blocks wait for Swift callbacks
    /// to finish before returning. Cancel the calling task to interrupt the execution.
    ///
    /// Standard output and error redirections append to absolute paths for this block.
    /// A source redirection saves recorded input to a new file. Implicit startup captures
    /// its own output.
    ///
    /// Set `recordingHistory` to false to exclude a block from `In`, `Out`, and numbering.
    /// An explicit reservation supplies the history number and requires `recordingHistory`.
    /// It is consumed before queue admission, including when that wait is cancelled.
    ///
    /// The scope is available to Swift exports and the file access delegate during the block.
    nonisolated func evaluate(
        _ source: String,
        scope: (any Sendable)? = nil,
        filename: String? = nil,
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
            recordingHistory: recordingHistory,
            reservation: reservation,
            redirecting: redirects,
            output: output,
            committing: committing,
        )
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
}

extension Session {
    nonisolated func run(
        _ source: Interpreter.Source,
        in context: Context? = nil,
        scope: (any Sendable)?,
        filename: String?,
        recordingHistory: Bool = true,
        reservation: Reservation? = nil,
        redirecting redirects: [Stream: FilePath],
        output: Control.OutputHandler?,
        committing: (@Sendable (Commit) async throws -> Void)? = nil,
    ) async throws -> Execution {
        let reservedNumber = try claim(reservation, for: source, recordingHistory: recordingHistory)
        let number = Mutex<Int?>(reservedNumber)

        let settlement = committing.map(Self.publicationSettlement)
        return try await withExecution(
            in: context,
            scope: scope,
            output: output,
            onInterruption: { result in
                Self.interruptedExecution(result, number: number.withLock { $0 })
            },
            settling: settlement,
            { session, execution in
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
            },
        )
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
            throw Failure("A reservation requires recorded interactive input.")
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
        } catch var failure as Failure where failure.output != nil {
            // Implicit startup can fail before the interactive block reaches the interpreter.
            failure.number = number
            throw failure
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

        let destination = try Self.sourceDestination(in: redirects)

        let reserved = number.withLock { $0 }
        let next = try reserved ?? history.reserveNumber()
        // Interruption must report the reserved number even if saving the source fails.
        number.withLock { $0 = next }
        try await history.save(source, number: next, destination: destination)
    }

    private static func sourceDestination(
        in redirects: [Stream: Runtime.Path],
    ) throws -> Runtime.Path? {
        guard let destination = redirects[.source] else {
            return nil
        }
        let sourcePath = destination.file.lexicallyNormalized()
        let hasConflictingRedirect = redirects.contains { stream, path in
            stream != .source && path.file.lexicallyNormalized() == sourcePath
        }
        if hasConflictingRedirect {
            throw Failure("A source history file must be separate from standard streams.")
        }
        return destination
    }
}

// MARK: - Execution outcome

private extension Session {
    @Sendable
    static func interruptedExecution(
        _ result: Swift::Result<Execution, any Swift::Error>,
        number: Int?,
    ) -> Execution {
        let captured: Output = switch result {
        case let .success(execution):
            execution.output
        case let .failure(failure as Failure):
            failure.output ?? .empty
        case .failure:
            .empty
        }

        return Execution(output: captured, end: .stopped, number: number)
    }

    static func publicationSettlement(
        committing: @escaping @Sendable (Commit) async throws -> Void,
    ) -> Control.Settlement<Execution> {
        { _, control, result in
            guard case .success = result else {
                return result
            }

            do {
                try control.checkInterruption()

                try await Commit.withPublication(using: control, committing)
                try control.finishCheckingInterruption()
                return result
            } catch {
                return control.isInterrupted ? result : .failure(error)
            }
        }
    }
}

// MARK: - Session.Commit

public extension Session {
    struct Commit: Sendable {
        private let sealExecution: @Sendable () throws -> Void

        /// Seals the execution for publication. Throws if cancelled or used after publication.
        public func seal() throws {
            try sealExecution()
        }

        fileprivate static func withPublication(
            using control: Control,
            _ body: @Sendable (Commit) async throws -> Void,
        ) async throws {
            // All copies share the same validity window, including copies retained by the host.
            let current = Mutex<Control?>(control)
            let commit = Commit {
                try current.withLock { active in
                    guard let active else {
                        throw Failure.closed
                    }
                    try active.finishCheckingInterruption()
                }
            }
            defer { current.withLock { $0 = nil } }
            try await body(commit)
        }
    }
}

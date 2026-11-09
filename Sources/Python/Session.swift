//
//  Created by Anton Spivak
//

import Synchronization

// MARK: - Session

/// An interactive namespace with a private interpreter and local package environment.
public actor Session {
    private nonisolated let executor: Interpreter.Executor
    private nonisolated let operations: Operations = .init()

    private nonisolated let activeExecution: Mutex<Control?> = .init(nil)

    private let directory: Runtime.Path?
    private var importPaths: [Runtime.Path]

    private let startup: Startup
    nonisolated let transactional: Bool
    private let modules: [Module]
    private var delegate: (any Delegate)?

    private(set) var environment: Environment?
    private var state: State = .idle

    /// Output from startup. Reset clears it, and close preserves the last captured value.
    public var startupOutput: Output? {
        switch state {
        case .idle:
            nil
        case let .ready(_, output):
            output
        case let .closed(output):
            output
        }
    }

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        unsafe executor.asUnownedSerialExecutor()
    }

    init(
        executor: Interpreter.Executor,
        directory: Runtime.Path?,
        importPaths: [Runtime.Path],
        modules: [Module],
        startup: Startup = .source(""),
        transactional: Bool = false,
        environment: sending Environment? = nil,
        delegate: (any Delegate)? = nil,
    ) {
        self.executor = executor
        self.directory = directory
        self.importPaths = importPaths
        self.modules = modules
        self.startup = startup
        self.transactional = transactional
        self.environment = environment
        self.delegate = delegate
    }

    isolated deinit {
        state = .closed(nil)
        environment = nil
        executor.finish()
    }

    func initializeRuntime() throws {
        try PThread.initializeRuntime()
    }

    private var resolvedImportPaths: [String] {
        var paths = [String]()
        if let projectDirectory = environment?.projectDirectory {
            paths.append(projectDirectory.string)
        }
        if let directory {
            paths.append(directory.string)
        }
        paths.append(contentsOf: importPaths.lazy.map(\.string))
        if let sitePackagesPath = environment?.sitePackagesPath {
            paths.append(sitePackagesPath)
        }
        return paths
    }

    func openInterpreterIfNeeded(
        execution: Control,
        redirecting redirects: [Stream: Runtime.Path] = [:],
    ) throws {
        guard state.isIdle else {
            return
        }
        try Task.checkCancellation()

        let opened = try Interpreter(
            execution: execution,
            importPaths: resolvedImportPaths,
            modules: modules,
            packages: environment?.packaging.packages ?? [],
            transactional: transactional,
            scheduleRelease: { [weak self] in Task { await self?.releasePendingReferences() } },
            session: self,
            delegate: delegate,
        )

        let output = try opened.initialize(
            startup,
            importPaths: importPaths,
            redirecting: redirects,
            execution: execution,
        )
        state = .ready(consume opened, output)
    }

    private func releasePendingReferences() {
        withOpenInterpreter { $0.releasePendingReferences() }
    }

    func withInterpreter<Result: ~Copyable>(
        execution: Control,
        generation: Reference.Store? = nil,
        _ body: (borrowing Interpreter) throws -> Result,
    ) throws -> Result {
        if generation == nil {
            try openInterpreterIfNeeded(execution: execution)
        }
        switch state {
        case let .ready(interpreter, _):
            if let generation, interpreter.references !== generation {
                throw Reference.wrongInterpreter()
            }
            return try body(interpreter)
        case .idle:
            throw Reference.wrongInterpreter()
        case .closed:
            throw Session.Error.closed
        }
    }

    func finishCheckpoint(_ outcome: Interpreter.CheckpointOutcome) {
        withOpenInterpreter { $0.finishCheckpoint(outcome) }
    }

    @discardableResult
    private func withOpenInterpreter<Result: ~Copyable>(
        _ body: (borrowing Interpreter) throws -> Result,
    ) rethrows -> Result? {
        switch state {
        case let .ready(interpreter, _):
            try body(interpreter)
        case .idle:
            nil
        case .closed:
            nil
        }
    }

    @discardableResult
    public nonisolated func stop() -> Bool {
        activeExecution.withLock { $0 }?.requestInterruption(.stopped) ?? false
    }

    public nonisolated var isRunning: Bool {
        activeExecution.withLock { $0 != nil }
    }

    /// Discards the interpreter and invalidates its references. Package changes can run before
    /// the next execution starts a new interpreter.
    public nonisolated func reset() async throws {
        try await withOperation { session in
            session.state = .idle
        }
    }

    var canReplacePackages: Bool {
        state.isIdle
    }

    /// Replaces the host-supplied import roots and their read permissions.
    /// Invalidated source modules are loaded again on their next import. Reset the
    /// session to replace a loaded module whose loader does not support invalidation.
    public nonisolated func replaceImportPaths(
        _ paths: [String],
        invalidatingModules modules: [String] = [],
    ) async throws {
        try await withOperation { session in
            let execution = try Control(timeout: nil)
            try await execution.run(on: session) { session in
                try session.changeImportPaths(
                    paths,
                    invalidatingModules: modules,
                    execution: execution,
                )
            }
        }
    }

    private func changeImportPaths(
        _ paths: [String],
        invalidatingModules modules: [String],
        execution: Control,
    ) throws {
        let replacement = try paths.map(Runtime.Path.init)
        let previous = importPaths
        importPaths = replacement
        do {
            try withOpenInterpreter {
                try $0.updateImports(
                    paths: resolvedImportPaths,
                    invalidatingModules: modules,
                    execution: execution,
                )
            }
        } catch {
            importPaths = previous
            throw error
        }
    }

    /// Finishes prior operations and releases the interpreter and environment lease.
    /// From a Python callback, requests closing after outstanding work finishes.
    public nonisolated func close() async {
        if Self.isInCallback {
            // The callback must return before the current operation can release its reservation.
            if isInOwnCallback {
                _ = stop()
            }
            Task.detached { await self.close() }
            return
        }
        await operations.drain { await finishClose() }
    }

    private func finishClose() async {
        state = .closed(startupOutput)
        delegate = nil
        await environment?.close()
        environment = nil
    }

    private nonisolated static var isInCallback: Bool {
        !Control.sessionPath.isEmpty || Interpreter.Storage.current()?.sessionOrigin != nil
    }

    nonisolated var origin: ObjectIdentifier {
        ObjectIdentifier(executor)
    }

    private nonisolated var isInOwnCallback: Bool {
        let identity = origin
        return Control.sessionPath.contains(identity)
            || Interpreter.Storage.current()?.sessionOrigin == identity
    }

    nonisolated func withExecution<Result: Sendable>(
        timeout: Duration? = nil,
        output: Control.OutputHandler? = nil,
        onInterruption: Control.InterruptionHandler<Result>? = nil,
        settling: Control.Settlement<Result>? = nil,
        _ operation: @Sendable (isolated Session, Control) async throws -> Result,
    ) async throws -> Result {
        try await withOperation { session in
            let execution = try Control(timeout: timeout, output: output)

            session.activeExecution.withLock { $0 = execution }
            defer { session.activeExecution.withLock { $0 = nil } }

            return try await execution.withCancellation {
                try await execution.run(
                    on: session,
                    onInterruption: onInterruption,
                    settling: settling,
                ) { session in
                    try await operation(session, execution)
                }
            }
        }
    }

    private nonisolated func withOperation<Result: Sendable>(
        _ operation: @Sendable (isolated Session) async throws -> Result,
    ) async throws -> Result {
        guard !isInOwnCallback else {
            throw Session.Error.busy
        }
        return try await operations.withReservation(Self.isInCallback ? .immediate : .queued) {
            try await perform(operation)
        }
    }

    private func perform<Result: Sendable>(
        _ operation: @Sendable (isolated Session) async throws -> Result,
    ) async throws -> Result {
        if state.isClosed {
            throw Session.Error.closed
        }
        try Task.checkCancellation()
        return try await operation(self)
    }
}

// MARK: Session.State

private extension Session {
    enum State: ~Copyable {
        case idle
        case ready(Interpreter, Output)
        case closed(Output?)

        var isIdle: Bool {
            switch self {
            case .idle:
                true
            default:
                false
            }
        }

        var isClosed: Bool {
            switch self {
            case .closed:
                true
            default:
                false
            }
        }
    }
}

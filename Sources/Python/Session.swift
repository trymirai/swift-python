//
//  Created by Anton Spivak
//

import Synchronization

// MARK: - Session

/// An interactive namespace with a private interpreter and local package environment.
public actor Session {
    private nonisolated let executor: InterpreterExecutor
    private nonisolated let activeExecution: Mutex<ExecutionControl?> = .init(nil)
    private let directory: String?
    private var importPaths: [String]
    private let modules: [Module]
    private let packages: [PackageSource]
    private let startup: Startup
    private let packageService: PackageService?
    private let packageConfiguration: PackageConfiguration?
    private let environmentDirectory: String?
    private let requirements: [String]
    private var environment: EnvironmentStore?
    private var interpreter: Interpreter?
    private var isClosed: Bool = false
    // A reservation spans package-service awaits and interpreter rollback. Keep
    // these operations under one owner so actor reentrancy cannot interleave them.
    private var isReserved: Bool = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Streams produced by the most recent successful initialization.
    public private(set) var startupOutput: Output?

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        unsafe executor.asUnownedSerialExecutor()
    }

    init(
        directory: String?,
        importPaths: [String],
        modules: [Module],
        packages: [PackageSource] = [],
        startup: Startup = .source(""),
        packageService: PackageService? = nil,
        packageConfiguration: PackageConfiguration? = nil,
        environmentDirectory: String? = nil,
        requirements: [String] = [],
    ) throws {
        self.directory = directory
        self.importPaths = try Runtime.paths(directory: directory, imports: importPaths)
        _ = try Runtime.paths(
            directory: startup.projectDirectory,
            imports: environmentDirectory.map { [$0] } ?? [],
        )
        self.modules = modules
        self.packages = packages
        self.startup = startup
        self.packageService = packageService
        self.packageConfiguration = packageConfiguration
        self.environmentDirectory = environmentDirectory
        self.requirements = requirements
        self.executor = try InterpreterExecutor()
    }

    isolated deinit {
        interpreter = nil
        environment = nil
        executor.finish()
    }

    func initializeRuntime() throws {
        try ThreadState.initialize()
    }

    private var resolvedImportPaths: [String] {
        (startup.projectDirectory.map { [$0] } ?? [])
            + importPaths + (environment?.path.map { [$0] } ?? [])
    }

    private func openInterpreterIfNeeded(execution: ExecutionControl) throws {
        switch interpreter {
        case .some:
            return
        case .none:
            break
        }

        try Task.checkCancellation()
        let opened = try Interpreter(
            importPaths: resolvedImportPaths,
            modules: modules,
            packages: packages,
            scheduleRelease: { [weak self] in Task { await self?.releasePendingReferences() } },
            sessionOrigin: ObjectIdentifier(executor),
        )
        startupOutput = try opened.initialize(startup, execution: execution)
        interpreter = consume opened
    }

    private func releasePendingReferences() {
        interpreter?.releasePendingReferences()
    }

    func withInterpreter<Result: ~Copyable>(
        execution: ExecutionControl,
        _ body: (borrowing Interpreter) throws -> Result,
    ) throws -> Result {
        try openInterpreterIfNeeded(execution: execution)
        switch interpreter {
        case let .some(interpreter):
            return try body(interpreter)
        case .none:
            throw SessionError.closed
        }
    }

    @discardableResult
    public nonisolated func stop() -> Bool {
        activeExecution.withLock { $0 }?.requestInterruption(.stopped) ?? false
    }

    public nonisolated var isRunning: Bool {
        activeExecution.withLock { $0 != nil }
    }

    /// Closes the interpreter. The next execution repeats initialization with the
    /// current packages; dependency operations can run before that re-import.
    public nonisolated func reset() async throws {
        try checkReentry()
        try await withOperation { session in
            session.interpreter = nil
            session.startupOutput = nil
            try session.environment?.prune()
        }
    }

    /// Application and local distribution versions visible to this session.
    public nonisolated func installedPackages() async throws -> [String: String] {
        try await withPackageOperation { _, environment, _, _ in
            environment.installedPackages()
        }
    }

    nonisolated func changePackages(_ change: EnvironmentStore.Change) async throws {
        try await withPackageOperation { session, environment, service, execution in
            let staged = try await environment.prepare(
                change,
                projectDirectory: session.startup.projectDirectory,
                additionalRequirements: session.requirements,
                using: service,
                execution: execution,
            )
            if let staged {
                try session.publishGeneration(staged, in: environment, execution: execution)
            } else {
                try execution.finishCheckingInterruption()
            }
        }
    }

    private nonisolated func withPackageOperation<Result: Sendable>(
        _ operation: @Sendable (
            isolated Session,
            EnvironmentStore,
            PackageService,
            ExecutionControl,
        )
        async throws -> Result,
    ) async throws -> Result {
        try await withExecution { session, execution in
            guard
                let service = session.packageService,
                let configuration = session.packageConfiguration
            else {
                throw SessionError.closed
            }

            let result: Result
            do {
                let environment = try session.openEnvironment(configuration: configuration)
                result = try await operation(session, environment, service, execution)
            } catch {
                try execution.finishCheckingInterruption()
                throw error
            }
            try execution.finishCheckingInterruption()
            return result
        }
    }

    private func openEnvironment(configuration: PackageConfiguration) throws -> EnvironmentStore {
        if let environment {
            return environment
        }
        let opened = try EnvironmentStore(
            directory: environmentDirectory,
            configuration: configuration,
        )
        environment = opened
        return opened
    }

    private func publishGeneration(
        _ staged: EnvironmentStore.Generation,
        in environment: EnvironmentStore,
        execution: ExecutionControl,
    ) throws {
        let previousGeneration = environment.generation
        let previousState = environment.state
        var didPublish = false
        do {
            let loaded = try interpreter?.loadedModules(
                files: staged.changedFiles,
                roots: environment.importRoots(),
                execution: execution,
            ) ?? []
            guard loaded.isEmpty else {
                throw SessionError.resetRequired(modules: loaded)
            }
            try execution.checkInterruption()
            try environment.publish(staged)
            didPublish = true
            try interpreter?.updateImports(
                paths: resolvedImportPaths,
                invalidatingModules: [],
                execution: execution,
            )
            try execution.finishCheckingInterruption()
        } catch {
            do {
                try environment.restore(
                    generation: previousGeneration,
                    state: previousState,
                    discarding: staged.id,
                )
                if didPublish {
                    try interpreter?.restoreImports(
                        paths: resolvedImportPaths,
                        discarding: [staged.path],
                    )
                }
                try environment.discard(staged.id)
            } catch {
                isClosed = true
                interpreter = nil
                throw RuntimeFailure("Package publication recovery failed: \(error)")
            }
            throw error
        }
    }

    /// Changes explicitly supplied import roots without changing installed packages.
    public nonisolated func replaceImportPaths(
        _ paths: [String],
        invalidatingModules modules: [String] = [],
    ) async throws {
        try checkReentry()
        try await withOperation { session in
            try session.changeImportPaths(paths, invalidatingModules: modules)
        }
    }

    private func changeImportPaths(
        _ paths: [String],
        invalidatingModules modules: [String],
    ) throws {
        let replacement = try Runtime.paths(directory: directory, imports: paths)
        let previous = importPaths
        importPaths = replacement
        do {
            try interpreter?.updateImports(
                paths: resolvedImportPaths,
                invalidatingModules: modules,
            )
        } catch {
            importPaths = previous
            throw error
        }
    }

    /// Finishes prior operations and releases the interpreter and environment lease.
    public nonisolated func close() async {
        if (try? checkReentry()) == nil {
            // The callback must return before the current operation can release its reservation.
            _ = stop()
            Task.detached { await self.finishClose() }
            return
        }
        await finishClose()
    }

    private func finishClose() async {
        await acquireOperation()
        defer {
            releaseOperation()
        }
        isClosed = true
        interpreter = nil
        try? environment?.close()
        environment = nil
    }

    private nonisolated func checkReentry() throws {
        let identity = ObjectIdentifier(executor)
        if
            CallbackOrigin.current.contains(identity) || InterpreterStorage.current()?
                .sessionOrigin == identity
        {
            throw Exception(
                name: "RuntimeError",
                message: "Use the current Python context; a callback cannot enqueue an operation on its own session.",
            )
        }
    }

    nonisolated func withExecution<Result: Sendable>(
        timeout: Duration? = nil,
        standardIO: StandardIO = .init(),
        onOutput: ExecutionControl.OutputHandler? = nil,
        _ operation: @Sendable (isolated Session, ExecutionControl) async throws -> Result,
    ) async throws -> Result {
        try checkReentry()
        let execution = try ExecutionControl(
            timeout: timeout,
            onOutput: onOutput,
            standardIO: standardIO,
        )
        return try await execution.withCancellation {
            try await withOperation(execution) { session in
                try await operation(session, execution)
            }
        }
    }

    private func withOperation<Result: Sendable>(
        _ execution: ExecutionControl? = nil,
        _ operation: @Sendable (isolated Session) async throws -> Result,
    ) async throws -> Result {
        await acquireOperation()
        defer {
            releaseOperation()
            _ = execution?.finish()
        }
        guard !isClosed else {
            throw SessionError.closed
        }
        try Task.checkCancellation()
        guard let execution else {
            return try await operation(self)
        }
        activeExecution.withLock { $0 = execution }
        defer { activeExecution.withLock { $0 = nil } }
        return try await operation(self)
    }

    private func acquireOperation() async {
        if isReserved {
            await withCheckedContinuation { operationWaiters.append($0) }
        } else {
            isReserved = true
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            isReserved = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}

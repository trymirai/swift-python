//
//  Created by Anton Spivak
//

/// A handle to the process-wide embedded Python runtime.
public struct Runtime: Sendable {
    private static let startup: Task<Void, any Swift::Error> = .detached {
        let session = Session(
            executor: try Interpreter.Executor(),
            directory: nil,
            importPaths: [],
            modules: [],
        )
        try await session.initializeRuntime()
    }

    static func initialize() async throws {
        try await startup.value
    }

    let packaging: Environment.Service.Lazy
    private let options: Options

    /// Creates a runtime with immutable application packages and a shared wheel cache.
    public init(
        packages: [PackageSource] = [],
        cacheDirectory: String? = nil,
        packageIndex: String = "https://pypi.org/simple/",
        options: Options = [],
    ) async throws {
        #if !(os(macOS) || os(Linux) || targetEnvironment(macCatalyst))
        if options.contains(.subprocesses) {
            throw Failure("Python subprocesses are unavailable on this platform.")
        }
        #endif
        try await Self.initialize()

        let packages = try packages.map { try $0.resolved() }
        let cache = try cacheDirectory.map(Path.init)
        let packaging = Environment.Service.Lazy(
            packages: packages,
            options: .init(
                cacheDirectory: cache,
                packageIndex: packageIndex,
            ),
        )
        if !packages.isEmpty || packageIndex != "https://pypi.org/simple/" {
            _ = try await packaging.open()
        }
        self.packaging = packaging
        self.options = options
    }

    /// Prepares dependencies and returns a session that starts Python on first use.
    ///
    /// A project supplies dependencies through `requirements.txt` or `pyproject.toml` at its root.
    /// Pass a stable `environmentDirectory` to reuse local packages
    /// across sessions. Call `Session.initialize(redirecting:)` to start Python explicitly.
    ///
    /// Local installations take precedence over session packages, followed by the
    /// runtime's packages. A project with an empty `packages` list uses its
    /// `site-packages` directory or the matching site-packages in its `.venv`.
    /// The first source of each distribution supplies its version. Incompatible
    /// requirements fail during preparation.
    ///
    /// `directory` and `importPaths` grant read access alongside project and package roots.
    /// The delegate decides other access. Relative OS paths use the process working directory.
    ///
    /// Transactional evaluation restores Python state and the positions of session-owned
    /// descriptors after failure or interruption. Filesystem mutations persist across rollback.
    public func session(
        _ startup: Session.Startup = .source(""),
        directory: String? = nil,
        environmentDirectory: String? = nil,
        packages: [PackageSource] = [],
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        transactional: Bool = false,
        delegate: (any Session.Delegate)? = nil,
    ) async throws -> Session {
        try await session(
            startup,
            directory: directory,
            environmentDirectory: environmentDirectory,
            packages: packages,
            importPaths: importPaths,
            modules: modules,
            moduleDefinitions: [],
            transactional: transactional,
            delegate: delegate,
        )
    }

    package func session(
        _ startup: Session.Startup = .source(""),
        directory: String? = nil,
        environmentDirectory: String? = nil,
        packages: [PackageSource] = [],
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        moduleDefinitions: [Module],
        transactional: Bool = false,
        delegate: (any Session.Delegate)? = nil,
    ) async throws -> Session {
        let definitions = try Module.Catalog.resolve(modules, definitions: moduleDefinitions)
        return try await makeSession(
            startup,
            directory: directory.map(Path.init),
            environmentDirectory: environmentDirectory.map(Path.init),
            packages: packages.map { try $0.resolved() },
            importPaths: importPaths.map(Path.init),
            modules: definitions,
            transactional: transactional,
            delegate: delegate,
        )
    }

    func makeSession(
        _ startup: Session.Startup = .source(""),
        directory: Path?,
        environmentDirectory: Path?,
        packages: [PackageSource.Resolved] = [],
        importPaths: [Path],
        modules: [Module],
        transactional: Bool = false,
        requirements: [String] = [],
        delegate: (any Session.Delegate)?,
    ) async throws -> Session {
        let environment = Environment(
            directory: environmentDirectory,
            projectDirectory: try startup.projectDirectory.map(Path.init),
            requirements: requirements,
            sessionPackages: packages,
            packaging: packaging,
        )

        let executor: Interpreter.Executor
        do {
            try await environment.prepare()
            executor = try Interpreter.Executor()
        } catch {
            await environment.close()
            throw error
        }

        return Session(
            executor: executor,
            directory: directory,
            importPaths: importPaths,
            modules: modules,
            startup: startup,
            transactional: transactional,
            allowsSubprocesses: options.contains(.subprocesses),
            environment: environment,
            delegate: delegate,
        )
    }

    /// Prepares a project's pure-Python dependencies as an embeddable site-packages ZIP.
    /// Include module to put the flat-layout project's package in the same archive.
    public func bundle(
        project directory: String,
        module: String? = nil,
        to output: String,
    ) async throws {
        let project = try Path(directory)
        let destination = try Path(output)
        try await withPackageService { service, configuration, execution in
            try await service.bundle(
                project: project,
                module: module,
                output: destination,
                configuration: configuration,
                execution: execution,
            )
        }
    }

    func withPackageService<Result>(
        _ operation: (
            Environment.Service,
            Environment.Configuration,
            Session.Control,
        ) async throws -> Result,
    ) async throws -> Result {
        try await Environment.withPackageOperation { execution in
            let (service, configuration) = try await packaging.open()
            return try await operation(service, configuration, execution)
        }
    }

    /// Clears cached wheels and unpacked packages after all users of the cache have stopped.
    /// Keep persistent environments and application packages in separate directories.
    public static func clearPackageCache(at directory: String) async throws {
        let cache = try Path(directory).file
        guard !cache.lexicallyNormalized().components.isEmpty else {
            throw Failure("Expected a dedicated package cache directory.")
        }
        try await Environment.clearCache(at: cache)
    }
}

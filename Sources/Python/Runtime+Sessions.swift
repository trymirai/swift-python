//
//  Created by Anton Spivak
//

public extension Runtime {
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
    /// Changes made before an error or interruption remain in the Python namespace.
    /// Filesystem and native resource operations take effect immediately.
    func session(
        _ startup: Session.Startup = .source(""),
        directory: String? = nil,
        environmentDirectory: String? = nil,
        packages: [PackageSource] = [],
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        history: Session.History? = nil,
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
            history: history,
            delegate: delegate,
        )
    }

    /// Opens a project session with the package sources from a previous preparation.
    ///
    /// Each session has its own interpreter. A missing `module` selects the first project package.
    func session(
        _ resources: ProjectResources,
        module: String? = nil,
        directory: String? = nil,
        environmentDirectory: String? = nil,
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        history: Session.History? = nil,
        delegate: (any Session.Delegate)? = nil,
    ) async throws -> Session {
        try await session(
            .project(directory: resources.project.string, module: module),
            directory: directory,
            environmentDirectory: environmentDirectory,
            packages: resources.sources,
            importPaths: importPaths,
            modules: modules,
            history: history,
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
        history: Session.History? = nil,
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
            history: history,
            delegate: delegate,
        )
    }

    internal func makeSession(
        _ startup: Session.Startup = .source(""),
        directory: Path?,
        environmentDirectory: Path?,
        packages: [PackageSource.Resolved] = [],
        importPaths: [Path],
        modules: [Module],
        history: Session.History? = nil,
        requirements: [String] = [],
        delegate: (any Session.Delegate)?,
    ) async throws -> Session {
        let history = try history.map(Session.History.Store.init)
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
            history: history,
            allowsSubprocesses: options.contains(.subprocesses),
            environment: environment,
            delegate: delegate,
        )
    }
}

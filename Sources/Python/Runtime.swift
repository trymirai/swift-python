//
//  Created by Anton Spivak
//

public import SystemPackage

/// A handle to the process-wide embedded Python runtime.
public struct Runtime: Sendable {
    private static let startup: Task<Void, any Swift::Error> = .detached {
        let session = try Session(directory: nil, importPaths: [], modules: [])
        try await session.initializeRuntime()
    }

    let packaging: Environment.Service.Lazy

    /// Creates a runtime with immutable application packages and a shared wheel cache.
    public init(
        packages: [PackageSource] = [],
        cacheDirectory: String? = nil,
        packageIndex: String = "https://pypi.org/simple/",
    ) async throws {
        try await Self.startup.value
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
    }

    /// Prepares dependencies and initializes a persistent interactive namespace.
    ///
    /// A project's requirements.txt or pyproject.toml sits beside its import package.
    /// The environment directory holds this session's local packages; pass a stable
    /// location to reuse them after closing the session. File APIs that use the OS
    /// working directory still observe the process-wide directory.
    /// The `redirecting` paths apply only to the initial execution of `startup`.
    public func session(
        _ startup: Session.Startup = .source(""),
        directory: String? = nil,
        environmentDirectory: String? = nil,
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        redirecting redirects: [Session.Stream: FilePath] = [:],
        delegate: (any Session.Delegate)? = nil,
    ) async throws -> Session {
        try await session(
            startup,
            directory: directory,
            environmentDirectory: environmentDirectory,
            importPaths: importPaths,
            modules: modules,
            moduleDefinitions: [],
            redirecting: redirects,
            delegate: delegate,
        )
    }

    package func session(
        _ startup: Session.Startup = .source(""),
        directory: String? = nil,
        environmentDirectory: String? = nil,
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        moduleDefinitions: [Module],
        redirecting redirects: [Session.Stream: FilePath] = [:],
        delegate: (any Session.Delegate)? = nil,
    ) async throws -> Session {
        let definitions = try Module.Catalog.resolve(modules, definitions: moduleDefinitions)
        let session = try Session(
            directory: directory.map(Path.init),
            importPaths: importPaths.map(Path.init),
            modules: definitions,
            startup: startup,
            packaging: packaging,
            environmentDirectory: environmentDirectory.map(Path.init),
            delegate: delegate,
        )
        do {
            try await session.prepare(redirecting: redirects)
            return session
        } catch {
            await session.close()
            throw error
        }
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
        let execution = try Session.Control(timeout: nil)
        return try await execution.withCancellation {
            defer { _ = execution.finish() }
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

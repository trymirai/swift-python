//
//  Created by Anton Spivak
//

/// A handle to the process-wide embedded Python runtime.
public struct Runtime: Sendable {
    private static let startup: Task<Void, any Swift.Error> = .detached {
        let session = try Session(directory: nil, importPaths: [], modules: [])
        try await session.initializeRuntime()
    }

    let packageService: PackageService
    let packageConfiguration: PackageConfiguration
    let packages: [PackageSource]

    /// Creates a runtime with immutable application packages and a shared wheel cache.
    public init(
        packages: [PackageSource] = [],
        cacheDirectory: String? = nil,
        packageIndex: String = "https://pypi.org/simple/",
    ) async throws {
        try await Self.startup.value
        _ = try Self.paths(directory: cacheDirectory, imports: packages.compactMap { source in
            switch source {
            case let .directory(path), let .archive(path):
                path
            case .embedded:
                nil
            }
        })
        let service = try PackageService()
        self.packageConfiguration = try await service.open(
            packages: packages,
            configuration: ServiceConfiguration(
                cacheDirectory: cacheDirectory,
                packageIndex: packageIndex,
            ),
        )
        self.packageService = service
        self.packages = packages
    }

    /// Prepares dependencies and initializes a persistent interactive namespace.
    ///
    /// A project's requirements.txt or pyproject.toml sits beside its import package.
    /// The environment directory holds this session's local packages; pass a stable
    /// location to reuse them after closing the session. File APIs that use the OS
    /// working directory still observe the process-wide directory.
    public func session(
        _ startup: Session.Startup = .source(""),
        directory: String? = nil,
        environmentDirectory: String? = nil,
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        moduleInstances: [any ModuleHost] = [],
        moduleDefinitions: [Module] = [],
        startupIO: StandardIO = .init(),
    ) async throws -> Session {
        let definitions = try ExportCatalog.resolve(
            modules,
            instances: moduleInstances,
            definitions: moduleDefinitions,
        )
        let session = try Session(
            directory: directory,
            importPaths: importPaths,
            modules: definitions,
            packages: packages,
            startup: startup,
            packageService: packageService,
            packageConfiguration: packageConfiguration,
            environmentDirectory: environmentDirectory,
        )
        do {
            try await session.prepare(standardIO: startupIO)
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
        _ = try Self.paths(directory: directory, imports: [output])
        let execution = try ExecutionControl(timeout: nil, onOutput: nil)
        try await execution.withCancellation {
            defer { _ = execution.finish() }
            try await packageService.bundle(
                project: directory,
                module: module,
                output: output,
                configuration: packageConfiguration,
                execution: execution,
            )
        }
    }

    static func paths(directory: String?, imports: [String]) throws -> [String] {
        let paths = (directory.map { [$0] } ?? []) + imports
        for path in paths where !path.hasPrefix("/") || path.utf8.contains(0) {
            throw RuntimeFailure("Expected an absolute Python path without NUL characters: \(path)")
        }
        return paths
    }
}

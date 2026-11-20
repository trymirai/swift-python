//
//  Created by Anton Spivak
//

public extension Runtime {
    /// The resolved cache layout, including the default root when none was supplied.
    var paths: Paths {
        get async throws {
            let (_, configuration) = try await packaging.open()
            return configuration.paths
        }
    }

    /// Resolves a project's dependencies into resources that live sessions can share.
    ///
    /// Compatible versions are reused until `update` is true or the requirements change.
    /// Resolution manifests are published atomically under `preparationsDirectory`.
    /// The installed files live in the runtime's `paths.environmentsDirectory`.
    func prepare(
        project directory: String,
        in preparationsDirectory: String,
        packages: [PackageSource] = [],
        update: Bool = false,
    ) async throws -> ProjectResources {
        let project = try Path(directory)
        let destination = try Path(preparationsDirectory)
        let sources = try packages.map { try $0.resolved() }

        return try await Environment.prepareShared(
            project: project,
            in: destination,
            packages: sources,
            using: packaging,
            update: update,
        )
    }

    /// Prepares a project's pure-Python dependencies as an embeddable site-packages ZIP.
    /// Pass `module` to include the flat-layout project package. For cross-platform bundles,
    /// supply the destination's PEP 508 platform markers in `targetEnvironment`.
    func bundle(
        project directory: String,
        module: String? = nil,
        targetEnvironment: [String: String] = [:],
        to output: String,
    ) async throws {
        let project = try Path(directory)
        let destination = try Path(output)
        try await withPackageService { service, configuration, execution in
            try await service.bundle(
                project: project,
                module: module,
                output: destination,
                targetEnvironment: targetEnvironment,
                configuration: configuration,
                execution: execution,
            )
        }
    }

    /// Clears cached wheel downloads, installations, and shared preparations.
    /// Close all users of the cache before clearing it.
    /// Keep persistent environments and application packages in separate directories.
    static func clearPackageCache(at directory: String) async throws {
        let cache = try Path(directory).file
        guard !cache.lexicallyNormalized().components.isEmpty else {
            throw Failure("Expected a dedicated package cache directory.")
        }
        try await Environment.clearCache(at: cache)
    }

    internal func withPackageService<Result>(
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
}

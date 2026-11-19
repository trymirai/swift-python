//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import SystemPackage

extension Environment {
    static func prepareShared(
        project: Runtime.Path,
        in directory: Runtime.Path,
        packages: [Runtime.PackageSource.Resolved],
        using packaging: Service.Lazy,
        update: Bool,
    ) async throws -> Runtime.ProjectResources {
        let environment = Environment(
            directory: nil,
            projectDirectory: project,
            requirements: [],
            sessionPackages: packages,
            packaging: packaging,
        )
        let (service, configuration) = try await environment.open()
        let baseSources = environment.sessionPackages.map(\.source)

        func prepare(using execution: Session.Control) async throws -> Runtime.ProjectResources {
            let requirements = try await service.projectRequirements(
                at: project,
                execution: execution,
            )
            let fingerprint = try await service.request(
                .resolutionFingerprint(requirements: requirements, base: configuration.base),
                execution: execution,
            )
            let paths = Runtime.Paths.preparation(in: directory.file, fingerprint: fingerprint)
            let previous = try await readSharedManifest(
                at: paths.manifestFile,
                fingerprint: fingerprint,
                abi: configuration.abi,
                using: service,
            )

            let (manifest, sitePackages) = try await resolveShared(
                requirements: requirements,
                previous: previous,
                configuration: configuration,
                update: update,
                using: service,
                execution: execution,
            )
            if previous != manifest {
                try await publishShared(manifest, at: paths, using: service, execution: execution)
            }

            var sources = baseSources
            if let sitePackages {
                sources.insert(.directory(sitePackages.string), at: 0)
            }
            return Runtime.ProjectResources(
                project: project,
                sources: sources,
                fingerprint: fingerprint,
                paths: paths,
            )
        }

        return try await service.preparations.withReservation(.queued) {
            try await withPackageOperation(prepare)
        }
    }

    private static func readSharedManifest(
        at file: FilePath,
        fingerprint: String,
        abi: [String],
        using service: Service,
    ) async throws -> Manifest? {
        guard let manifest = try await readManifest(at: file, using: service, as: Manifest.self)
        else {
            return nil
        }
        guard
            manifest.abi == abi,
            manifest.fingerprint == fingerprint,
            manifest.local.isEmpty
        else {
            throw Runtime.Failure("Invalid shared package preparation: \(file)")
        }
        return manifest
    }

    private static func resolveShared(
        requirements: [String],
        previous: Manifest?,
        configuration: Configuration,
        update: Bool,
        using service: Service,
        execution: Session.Control,
    ) async throws -> (manifest: Manifest, sitePackages: FilePath?) {
        let cache = configuration.paths
        let installed = previous?.packages ?? [:]
        let cached = try await sharedPackagesDirectory(
            for: installed,
            in: cache,
            using: service,
            execution: execution,
        )
        let fingerprint: String? = if let cached, try await !hasEnvironmentDirectory(at: cached) {
            nil
        } else {
            previous?.fingerprint
        }

        // Keep the selected wheels for offline repair even when the assembly needs rebuilding.
        let preparation = try await service.request(
            .prepare(
                requirements: requirements,
                base: configuration.base,
                installed: installed,
                fingerprint: fingerprint,
                update: update,
            ),
            execution: execution,
        )

        switch preparation {
        case .unchanged:
            guard let previous else {
                throw Runtime.Failure("A shared preparation returned no package records.")
            }
            return (previous, cached)
        case let .resolved(resolution):
            return try await assembleShared(
                resolution,
                configuration: configuration,
                using: service,
                execution: execution,
            )
        case .requiresReset:
            throw Runtime.Failure("Shared dependency preparation unexpectedly requires a reset.")
        }
    }

    private static func assembleShared(
        _ resolution: Preparation.Resolution,
        configuration: Configuration,
        using service: Service,
        execution: Session.Control,
    ) async throws -> (manifest: Manifest, sitePackages: FilePath?) {
        let manifest = Manifest(abi: configuration.abi).updating(local: [:], resolution: resolution)
        let cache = configuration.paths
        let sitePackages = try await sharedPackagesDirectory(
            for: manifest.packages,
            in: cache,
            using: service,
            execution: execution,
        )

        if let sitePackages {
            try await stageSharedFiles(
                resolution,
                at: sitePackages,
                in: cache,
                execution: execution,
            )
        }
        return (manifest, sitePackages)
    }

    private static func sharedPackagesDirectory(
        for packages: [String: InstalledPackage],
        in cache: Runtime.Paths,
        using service: Service,
        execution: Session.Control,
    ) async throws -> FilePath? {
        guard !packages.isEmpty else {
            return nil
        }
        let digest = try await service.request(.packageFingerprint(packages), execution: execution)
        return cache.environmentPackagesDirectory(digest: digest)
    }

    private static func stageSharedFiles(
        _ resolution: Preparation.Resolution,
        at sitePackages: FilePath,
        in cache: Runtime.Paths,
        execution: Session.Control,
    ) async throws {
        guard try await !hasEnvironmentDirectory(at: sitePackages) else {
            return
        }

        let target = sitePackages.removingLastComponent()
        let staged = cache.environmentStagingDirectory(identifier: identifier())
        defer { await discard(staged) }

        let paths = Runtime.Paths.Environment(directory: staged)
        try await stageFiles(
            resolution,
            into: paths.temporaryPackagesDirectory,
            execution: execution,
        )
        try execution.checkInterruption()

        do {
            try await FileSystem.shared.moveItem(at: staged, to: target)
        } catch let error as FileSystemError {
            // Another runtime may have published the same immutable wheel set.
            guard try await hasEnvironmentDirectory(at: sitePackages) else {
                throw error
            }
        }
    }

    private static func hasEnvironmentDirectory(at path: FilePath) async throws -> Bool {
        try await FileSystem.shared.info(forFileAt: path)?.type == .directory
    }

    private static func publishShared(
        _ manifest: Manifest,
        at paths: Runtime.Paths.Environment,
        using service: Service,
        execution: Session.Control,
    ) async throws {
        try await createStorageDirectory(at: paths.directory)
        let staged = paths.stagedManifestFile(identifier: identifier())
        defer { try? unlinkIfPresent(staged) }

        try await publishManifest(
            manifest,
            stagingAt: staged,
            to: paths.manifestFile,
            using: service,
            execution: execution,
        )
    }
}

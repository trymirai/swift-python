//
//  Created by Anton Spivak
//

// MARK: - Environment.Change

extension Environment {
    enum Change: Sendable {
        case resolve
        case update
        case install([String])
        case uninstall([String])

        var updatesInstalledVersions: Bool {
            if case .update = self {
                true
            } else {
                false
            }
        }
    }
}

extension Environment {
    func prepare() async throws {
        guard needsPreparation else {
            return
        }

        try await Self.withPackageOperation { execution in
            _ = try await apply(.resolve, canReplacePackages: true, execution: execution)
        }
    }

    static func withPackageOperation<Result>(
        _ operation: (Session.Control) async throws -> Result,
    ) async throws -> Result {
        let execution = try Session.Control()
        return try await execution.withCancellation {
            defer { _ = execution.finish() }
            let result = try await operation(execution)
            try execution.finishCheckingInterruption()
            return result
        }
    }

    func apply(
        _ change: Change,
        canReplacePackages: Bool,
        execution: Session.Control,
    ) async throws -> Session.Packages.Change {
        if case .resolve = change, !needsPreparation, manifest == nil {
            return .applied
        }

        let (service, configuration) = try await open()
        let previous = manifest ?? Manifest(abi: configuration.abi)

        let requirements = try await resolutionRequirements(using: service, execution: execution)
        let local = try await localRequirements(
            after: change,
            manifest: previous,
            configuration: configuration,
            using: service,
            execution: execution,
        )

        let request = Service.Request.prepare(
            requirements: requirements,
            base: configuration.base,

            local: local.ordered,
            removed: local.removed,
            installed: previous.packages,
            fingerprint: previous.fingerprint,

            update: change.updatesInstalledVersions,
            replaceFiles: canReplacePackages,
        )
        let preparation = try await service.request(request, execution: execution)
        try execution.checkInterruption()

        let resolution: Preparation.Resolution?
        switch preparation {
        case .unchanged:
            resolution = nil
        case .requiresReset:
            return .requiresReset
        case let .resolved(value):
            resolution = value
        }

        let next = previous.updating(local: local.byName, resolution: resolution)
        guard next != previous else {
            return .applied
        }

        let replacesFiles = !next.hasSameWheels(as: previous)
        try await save(
            next,
            replacingFiles: replacesFiles ? resolution : nil,
            using: service,
            configuration: configuration,
            execution: execution,
        )
        return .applied
    }

    private func resolutionRequirements(
        using service: Service,
        execution: Session.Control,
    ) async throws -> [String] {
        guard let projectDirectory else {
            return requirements
        }

        let project = try await service.projectRequirements(
            at: projectDirectory,
            execution: execution,
        )
        return project + requirements
    }

    private func localRequirements(
        after change: Change,
        manifest: Manifest,
        configuration: Configuration,
        using service: Service,
        execution: Session.Control,
    ) async throws -> (byName: [String: String], ordered: [String], removed: [String]) {
        var byName = manifest.local
        var order = byName.keys.sorted()
        var removed = [String]()

        switch change {
        case let .install(requirements):
            let additions = try await service.request(
                .normalize(requirements),
                execution: execution,
            )
            for requirement in additions {
                if byName.updateValue(requirement.declaration, forKey: requirement.name) == nil {
                    order.append(requirement.name)
                }
            }
        case let .uninstall(packages):
            removed = try await service.request(
                .names(packages),
                execution: execution,
            )
            byName = try manifest.removingLocalRequirements(removed, base: configuration.base)
        case .resolve, .update:
            break
        }

        // Preserve the order of newly requested packages after the saved names.
        return (byName, order.compactMap { byName[$0] }, removed)
    }
}

private extension Environment.Manifest {
    func removingLocalRequirements(
        _ names: [String],
        base: [String: Environment.BasePackage],
    ) throws -> [String: String] {
        var remaining = local
        for name in names {
            let supplied = base[name] != nil
            let overridesBase = supplied && packages[name] != nil
            guard remaining.removeValue(forKey: name) != nil || overridesBase else {
                let message = if supplied {
                    "Package '\(name)' belongs to a supplied source and cannot be uninstalled locally"
                } else {
                    "Package '\(name)' is required by the project or another package"
                }
                throw Failure(.valueError, message: message)
            }
        }
        return remaining
    }
}

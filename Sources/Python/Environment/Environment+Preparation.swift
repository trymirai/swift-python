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
        let execution = try Session.Control(timeout: nil)
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

        let project: [String] = if let projectDirectory {
            try await service.projectRequirements(at: projectDirectory, execution: execution)
        } else {
            []
        }
        let local = try await localRequirements(
            after: change,
            manifest: previous,
            configuration: configuration,
            using: service,
            execution: execution,
        )

        let request = Service.Request.prepare(
            requirements: project + requirements,
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
        case let .resolved(resolved):
            resolution = resolved
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

        func remove(_ name: String) throws {
            let isSupplied = configuration.base[name] != nil
            let overridesBase = isSupplied && manifest.packages[name] != nil
            guard byName.removeValue(forKey: name) != nil || overridesBase else {
                let message = if isSupplied {
                    "Package '\(name)' belongs to a supplied source and cannot be uninstalled locally"
                } else {
                    "Package '\(name)' is required by the project or another package"
                }
                throw Exception(name: "ValueError", message: message)
            }
            removed.append(name)
        }

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
            let names = try await service.request(
                .names(packages),
                execution: execution,
            )
            for name in names {
                try remove(name)
            }
        case .resolve, .update:
            break
        }

        // Preserve the order of newly requested packages after the saved names.
        return (byName, order.compactMap { byName[$0] }, removed)
    }
}

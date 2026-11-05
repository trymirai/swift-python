//
//  Created by Anton Spivak
//

// MARK: - EnvironmentStore.Change

extension EnvironmentStore {
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

extension EnvironmentStore {
    func prepare(
        _ change: Change,
        projectDirectory: String?,
        additionalRequirements: [String],
        using service: PackageService,
        execution: ExecutionControl,
    ) async throws -> Generation? {
        let project = try await service.request(
            .readingProject(at: projectDirectory),
            as: [String].self,
            execution: execution,
        ) + additionalRequirements
        let local = try await localRequirements(after: change, using: service, execution: execution)
        let preparation = try await service.request(
            .prepare(
                requirements: project + local.ordered,
                installed: state.packages,
                fingerprint: state.fingerprint,
                update: change.updatesInstalledVersions,
            ),
            as: PackagePreparation.self,
            execution: execution,
        )
        try execution.checkInterruption()
        guard !preparation.isUnchanged else {
            return nil
        }
        return try stage(
            preparation,
            requirements: project,
            local: local.byName,
            execution: execution,
        )
    }

    private func localRequirements(
        after change: Change,
        using service: PackageService,
        execution: ExecutionControl,
    ) async throws -> (byName: [String: String], ordered: [String]) {
        var byName = state.local
        var order = byName.keys.sorted()

        switch change {
        case let .install(requirements):
            let additions = try await service.request(
                .normalize(requirements),
                as: [PackageRequirement].self,
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
                as: [String].self,
                execution: execution,
            )
            for name in names {
                guard configuration.baseVersions[name] == nil else {
                    throw Exception(
                        name: "ValueError",
                        message: "Application package '\(name)' cannot be uninstalled locally",
                    )
                }
                guard byName.removeValue(forKey: name) != nil else {
                    throw Exception(
                        name: "ValueError",
                        message: "Package '\(name)' is required by the project or another package",
                    )
                }
            }
        case .resolve, .update:
            break
        }
        return (byName, order.compactMap { byName[$0] })
    }
}

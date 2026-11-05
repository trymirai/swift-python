//
//  Created by Anton Spivak
//

internal import Foundation

extension PackageService {
    func bundle(
        project: String,
        module: String?,
        output: String,
        configuration: PackageConfiguration,
        execution: ExecutionControl,
    ) throws {
        let environment = try EnvironmentStore(directory: nil, configuration: configuration)
        defer { try? environment.close() }
        let requirements = try request(
            .readingProject(at: project),
            as: [String].self,
            execution: execution,
        )
        let preparation = try request(
            .prepare(
                requirements: requirements,
                installed: [:],
                fingerprint: nil,
                update: false,
            ),
            as: PackagePreparation.self,
            execution: execution,
        )
        let staged = try environment.stage(
            preparation,
            requirements: requirements,
            local: [:],
            execution: execution,
        )
        if let module {
            let name = try request(.moduleName(module), as: String.self, execution: execution)
            try EnvironmentStore.includeModule(
                name,
                project: project,
                destination: staged.path,
                execution: execution,
            )
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + "." + EnvironmentStore
                .identifier())
            .path
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        _ = try request(
            .archive(directory: staged.path, output: temporary),
            as: ServiceAcknowledgement.self,
            execution: execution,
        )
        try execution.finishCheckingInterruption()
        try EnvironmentStore.publishArchive(temporary, to: output)
    }
}

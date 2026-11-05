//
//  Created by Anton Spivak
//

import ArgumentParser
import SystemPackage

extension CPythonBuild {
    struct Prepare: AsyncParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "prepare",
            abstract: "Generate frozen modules, resources and getpath code.",
        )

        @ParentCommand
        var parent: CPythonBuild

        @Argument(help: "Swift package directory.", transform: { FilePath($0) })
        var packageDirectory: FilePath

        @Argument(
            help: "Generated-output and host-build cache directory.",
            transform: { FilePath($0) },
        )
        var outputDirectory: FilePath

        @Option(help: "Parallel compiler jobs.")
        var jobs: Int = 6

        func validate() throws {
            guard packageDirectory.isAbsolute, outputDirectory.isAbsolute else {
                throw ValidationError("The package and output directories must be absolute.")
            }
            guard jobs > 0 else {
                throw ValidationError("--jobs must be positive.")
            }
        }

        func run() async throws {
            let workspace = BuildWorkspace(
                packageDirectory: packageDirectory,
                outputDirectory: outputDirectory,
                logger: parent.makeLogger(),
            )

            let build = StandardLibraryBuilder(workspace: workspace, jobCount: jobs)
            try await build.run()
        }
    }
}

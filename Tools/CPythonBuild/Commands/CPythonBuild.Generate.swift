//
//  Created by Anton Spivak
//

import _NIOFileSystem
import ArgumentParser
import SystemPackage

extension CPythonBuild {
    struct Generate: AsyncParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "generate",
            abstract: "Regenerate the bundled library sources.",
        )

        @ParentCommand
        var parent: CPythonBuild

        @Argument(help: "Swift package directory.", transform: { FilePath($0) })
        var packageDirectory: FilePath?

        @Option(help: "Parallel compiler jobs.")
        var jobs: Int = 6

        func validate() throws {
            if let packageDirectory, !packageDirectory.isAbsolute {
                throw ValidationError("The package directory must be absolute.")
            }
            guard jobs > 0 else {
                throw ValidationError("--jobs must be positive.")
            }
        }

        func run() async throws {
            let fileSystem = FileSystem.shared
            let package = if let packageDirectory {
                packageDirectory
            } else {
                try await fileSystem.currentWorkingDirectory
            }

            let build = package.appending(".build")

            try await fileSystem.createDirectory(at: build, withIntermediateDirectories: true)
            try await fileSystem.withTemporaryDirectory(prefix: build) { _, directory in
                let workspace = BuildWorkspace(
                    packageDirectory: package,
                    outputDirectory: directory,
                    logger: parent.makeLogger(),
                )
                try await Self.generateOpenSSL(in: workspace, jobs: jobs)
            }
        }
    }
}

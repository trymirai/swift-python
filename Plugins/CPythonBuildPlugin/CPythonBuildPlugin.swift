//
//  Created by Anton Spivak
//

import PackagePlugin

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - CPythonBuildPlugin

@main
struct CPythonBuildPlugin {}

// MARK: BuildToolPlugin

extension CPythonBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        let packageDirectory = context.package.directoryURL
        let tool = try context.tool(named: "CPythonBuild").url

        // Xcode supplies a symbolic tool path and can plan several platforms for one target.
        // Give each variant its own generated sources inside the plugin work directory.
        let outputDirectory = if tool.path.hasPrefix("/${BUILD_DIR}/") {
            context
                .pluginWorkDirectoryURL
                .appending(path: "$(PLATFORM_NAME)$(EFFECTIVE_PLATFORM_NAME)")
        } else {
            context.pluginWorkDirectoryURL
        }

        let inputs = try InputFiles(packageDirectory: packageDirectory.path).collect()
        return [.buildCommand(
            displayName: "Prepare embedded CPython sources",
            executable: tool,
            arguments: ["prepare", packageDirectory.path, outputDirectory.path],
            environment: [
                "LLVM_PROFILE_FILE": outputDirectory
                    .appending(path: "CPythonBuild-%m.profraw")
                    .path,
            ],
            inputFiles: inputs.map { packageDirectory.appending(path: $0) },
            outputFiles: [
                "Frozen.c",
                "Resources.c",
                "GetPath.c",
                "FileIO.c",
                "PosixModule.c",
                "Import.c",
                "SocketModule.c",
                "SelectModule.c",
                "ThreadModule.c",
            ]
            .map { outputDirectory.appending(path: $0) },
        )]
    }
}

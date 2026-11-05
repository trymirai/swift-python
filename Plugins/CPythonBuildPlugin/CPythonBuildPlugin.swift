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
        let outputDirectory = context.pluginWorkDirectoryURL

        let inputs = try InputFiles(packageDirectory: packageDirectory.path).collect()
        return [try .buildCommand(
            displayName: "Build embedded CPython standard library",
            executable: context.tool(named: "CPythonBuild").url,
            arguments: ["prepare", packageDirectory.path, outputDirectory.path],
            environment: [
                "LLVM_PROFILE_FILE": outputDirectory
                    .appending(path: "CPythonBuild-%m.profraw")
                    .path,
            ],
            inputFiles: inputs.map { packageDirectory.appending(path: $0) },
            outputFiles: ["Frozen.c", "Resources.c", "GetPath.c"]
                .map { outputDirectory.appending(path: $0) },
        )]
    }
}

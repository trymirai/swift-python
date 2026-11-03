//
//  Created by Anton Spivak
//

import PackagePlugin

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - CPythonBuildPlugin

@main
struct CPythonBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        let package = context.package.directoryURL
        let output = context.pluginWorkDirectoryURL

        let inputs = try InputPaths(packageDirectory: package.path).collect()
        return [try .buildCommand(
            displayName: "Build embedded CPython standard library",
            executable: context.tool(named: "CPythonBuild").url,
            arguments: ["prepare", package.path, output.path],
            environment: [
                "LLVM_PROFILE_FILE": output.appending(path: "CPythonBuild-%m.profraw").path,
            ],
            inputFiles: inputs.map { package.appending(path: $0) },
            outputFiles: ["Frozen.c", "Resources.c", "GetPath.c"]
                .map { output.appending(path: $0) },
        )]
    }
}

// MARK: CPythonBuildPlugin.InputPaths

extension CPythonBuildPlugin {
    // Build-tool plugins cannot import package products such as NIOFileSystem.
    // Visit directories with libc so edits to any upstream input invalidate generation.
    struct InputPaths: ~Copyable {
        let packageDirectory: String

        func collect() throws -> [String] {
            let directories = [
                "Sources/libcpython/Generated/Configuration",
                "Submodules/cpython/Include",
                "Submodules/cpython/Objects",
                "Submodules/cpython/Parser",
                "Submodules/cpython/Python",
                "Submodules/cpython/Modules",
                "Submodules/cpython/Lib",
                "Submodules/cpython/Programs",
            ]

            // The manifest and tool are tracked by SwiftPM; enumerate the files the build tool reads.
            var inputs = [String]()
            for path in directories {
                try visit(path, into: &inputs)
            }

            inputs.append(contentsOf: [
                "Sources/libcpython/Compatibility/Importer.py",

                "Submodules/cpython/Tools/freeze/flag.py",
                "Submodules/cpython/configure",
                "Submodules/cpython/Makefile.pre.in",
                "Submodules/cpython/config.guess",
                "Submodules/cpython/config.sub",
            ])

            return inputs.sorted()
        }

        private func visit(_ path: String, into inputs: inout [String]) throws {
            inputs.append(path)
            guard let directory = opendir(packageDirectory + "/" + path) else {
                throw MissingInputError(path: path)
            }
            defer { closedir(directory) }

            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 {
                        throw MissingInputError(path: path)
                    }
                    break
                }

                // dirent belongs to readdir until the next call; decode its name inside that borrow.
                let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                }

                if Self.omitted.contains(name) {
                    continue
                }

                let child = path + "/" + name
                var info = stat()

                guard lstat(packageDirectory + "/" + child, &info) == 0 else {
                    throw MissingInputError(path: child)
                }

                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    try visit(child, into: &inputs)
                } else if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                    inputs.append(child)
                }
            }
        }
    }
}

// MARK: CPythonBuildPlugin.MissingInputError

extension CPythonBuildPlugin {
    struct MissingInputError: Error {
        let path: String
    }
}

// MARK: - CPythonBuildPlugin.MissingInputError + CustomStringConvertible

extension CPythonBuildPlugin.MissingInputError: CustomStringConvertible {
    var description: String {
        "Cannot inspect package input: \(path)"
    }
}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension CPythonBuildPlugin.MissingInputError: LocalizedError {
    var errorDescription: String? {
        description
    }
}

#endif

private extension CPythonBuildPlugin.InputPaths {
    static let omitted: Set<String> = [
        ".",
        "..",
        ".git",
        "__pycache__",
        "test",
        "tests",
        "idlelib",
        "tkinter",
        "turtledemo",
        "ensurepip",
    ]
}

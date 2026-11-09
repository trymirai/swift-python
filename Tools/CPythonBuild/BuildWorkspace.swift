//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Logging
import Subprocess
import SystemPackage

// MARK: - BuildWorkspace

struct BuildWorkspace: ~Copyable {
    let fileSystem: FileSystem = .shared

    let packageDirectory: FilePath
    let outputDirectory: FilePath

    let logger: Logger

    var sourceDirectory: FilePath {
        packageDirectory.appending("Submodules/cpython")
    }
}

extension BuildWorkspace {
    func entries(_ path: FilePath) async throws -> [String] {
        try await fileSystem.withDirectoryHandle(atPath: path) { handle in
            var result = [String]()
            for try await entry in handle.listContents() {
                result.append(entry.name.string)
            }
            return result.sorted()
        }
    }

    func paths(_ root: FilePath, omitting: Set<String>) async throws -> [String] {
        try await fileSystem.withDirectoryHandle(atPath: root) { handle in
            var result = [String]()
            for try await entry in handle.listContents(recursive: true)
                where entry.type == .regular
            {
                var path = entry.path
                if
                    path.removePrefix(root),
                    !path.components.contains(where: { omitting.contains($0.string) })
                {
                    result.append(path.string)
                }
            }
            return result
        }
    }
}

extension BuildWorkspace {
    func read(textFrom path: FilePath) async throws -> String {
        try await String(
            contentsOf: path,
            maximumSizeAllowed: .mebibytes(128),
            fileSystem: fileSystem,
        )
    }

    func write(_ text: borrowing String, to path: FilePath) async throws {
        if
            try await fileSystem.info(forFileAt: path) != nil,
            try await read(textFrom: path) == text
        {
            return
        }

        try await text.write(
            toFileAt: path,
            options: .newFile(replaceExisting: true),
            fileSystem: fileSystem,
        )
    }
}

extension BuildWorkspace {
    func run<Output: OutputProtocol>(
        _ executable: FilePath,
        _ arguments: [String],
        in workingDirectory: FilePath,
        stage: String,
        environment: Environment = .inherit,
        output: Output = .currentStandardOutput,
    ) async throws -> Output.OutputType {
        logger.debug("\(stage)")
        // Convert through String because Subprocess uses the SDK's FilePath on Apple.
        let command: Executable = executable.isAbsolute
            ? .path(.init(executable.string))
            : .name(executable.string)
        let result = try await Subprocess::run(
            command,
            arguments: .init(arguments),
            environment: environment,
            workingDirectory: .init(workingDirectory.string),
            output: output,
            error: .currentStandardError,
        )
        guard result.terminationStatus == .exited(0) else {
            throw BuildError("\(stage) failed (\(result.terminationStatus)).")
        }
        return result.standardOutput
    }
}

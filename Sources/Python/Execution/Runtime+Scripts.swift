//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import SystemPackage

// MARK: Runtime + Scripts

public extension Runtime {
    /// Runs a UTF-8 script in a fresh session with its PEP 723 dependencies.
    /// Source is snapshotted before dependency preparation.
    /// The script's directory is an import root; process cwd remains unchanged.
    /// Omit environmentDirectory for a temporary environment, or supply one for
    /// reuse. The session closes on every outcome. Output files remain host-owned.
    func run(
        script path: String,
        arguments: [String] = [],
        environmentDirectory: String? = nil,
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        timeout: Duration? = nil,
        standardIO: StandardIO = .init(),
        onOutput: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Output {
        let definitions = try ExportCatalog.resolve(modules)
        _ = try Self.paths(directory: nil, imports: [path])
        try ExecutionControl.validateTimeout(timeout)
        let file = FilePath(path)
        let source = try await FileSystem.shared.withFileHandle(forReadingAt: file) { handle in
            let buffer = try await handle.readToEnd(maximumSizeAllowed: .unlimited)
            let bytes = buffer.readableBytesView
            let prefix = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            guard let source = String(validating: bytes.dropFirst(prefix), as: UTF8.self) else {
                throw RuntimeFailure("Python script source must be UTF-8.")
            }
            return source
        }
        let requirements = try await scriptRequirements(source)
        let session = try Session(
            directory: file.removingLastComponent().string,
            importPaths: importPaths,
            modules: definitions,
            packages: packages,
            packageService: packageService,
            packageConfiguration: packageConfiguration,
            environmentDirectory: environmentDirectory,
            requirements: requirements,
        )
        do {
            try await session.prepare()
            let output = try await session.run(
                .script(source, arguments: arguments),
                filename: path,
                timeout: timeout,
                standardIO: standardIO,
                onOutput: onOutput,
            )
            await session.close()
            return output
        } catch {
            await session.close()
            throw error
        }
    }
}

extension Runtime {
    private func scriptRequirements(_ source: String) async throws -> [String] {
        let execution = try ExecutionControl(timeout: nil, onOutput: nil)
        return try await execution.withCancellation {
            defer { _ = execution.finish() }
            let result = try await packageService.request(
                .script(source: source),
                as: [String].self,
                execution: execution,
            )
            try execution.checkInterruption()
            return result
        }
    }
}

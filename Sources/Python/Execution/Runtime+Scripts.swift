//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
public import SystemPackage

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
        redirecting redirects: [Session.Stream: FilePath] = [:],
        _ output: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Execution {
        let definitions = try Module.Catalog.resolve(modules)
        try Session.Control.validateTimeout(timeout)
        let file = try Path(path).file
        let source = try await Self.readScript(at: file)
        let requirements = try await scriptRequirements(source)

        let session = try Session(
            directory: Path(file.removingLastComponent()),
            importPaths: importPaths.map(Path.init),
            modules: definitions,
            packaging: packaging,
            environmentDirectory: environmentDirectory.map(Path.init),
            requirements: requirements,
        )

        do {
            try await session.prepare()
            let execution = try await session.run(
                .script(source, arguments: arguments),
                filename: path,
                timeout: timeout,
                redirecting: redirects,
                output: output,
            )
            await session.close()
            return execution
        } catch {
            await session.close()
            throw error
        }
    }
}

extension Runtime {
    private static func readScript(at path: FilePath) async throws -> String {
        try await FileSystem.shared.withFileHandle(forReadingAt: path) { handle in
            let buffer = try await handle.readToEnd(maximumSizeAllowed: .unlimited)
            let bytes = buffer.readableBytesView
            let bomLength = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            guard let source = String(validating: bytes.dropFirst(bomLength), as: UTF8.self) else {
                throw Runtime.Failure("Python script source must be UTF-8.")
            }
            return source
        }
    }

    private func scriptRequirements(_ source: String) async throws -> [String] {
        // A script without the header cannot contain PEP 723 requirements.
        guard source.contains("# /// script") else {
            return []
        }
        return try await withPackageService { service, _, execution in
            let result = try await service.request(
                .script(source: source),
                execution: execution,
            )
            try execution.checkInterruption()
            return result
        }
    }
}

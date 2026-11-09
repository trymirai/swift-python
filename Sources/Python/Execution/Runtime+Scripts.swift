//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import NIOPosix
public import SystemPackage

// MARK: Runtime + Scripts

public extension Runtime {
    /// Runs a UTF-8 script in a fresh session with its PEP 723 dependencies.
    ///
    /// The delegate checks the resolved source before reading it. Approval covers that file.
    /// Pass `importPaths` to grant additional reads. Without a delegate, the caller authorizes
    /// the source and its directory becomes a readable import root.
    ///
    /// The timeout starts after reading the source and preparing dependencies. Omit
    /// `environmentDirectory` for a temporary environment. The session closes on every outcome.
    func run(
        script path: String,
        arguments: [String] = [],
        environmentDirectory: String? = nil,
        importPaths: [String] = [],
        modules: [any ModuleHost.Type] = [],
        timeout: Duration? = nil,
        redirecting redirects: [Session.Stream: FilePath] = [:],
        delegate: (any Session.Delegate)? = nil,
        _ output: (@Sendable (Output.Stream, String) -> Void)? = nil,
    ) async throws -> Execution {
        try Session.Control.validateTimeout(timeout)
        let definitions = try Module.Catalog.resolve(modules)
        let script = try await Self.readScript(at: path, delegate: delegate)
        let requirements = try await scriptRequirements(script.source)

        let session = try await makeSession(
            directory: script.importDirectory,
            environmentDirectory: environmentDirectory.map(Path.init),
            importPaths: importPaths.map(Path.init),
            modules: definitions,
            requirements: requirements,
            delegate: delegate,
        )

        defer { await session.close() }
        return try await session.run(
            .script(script.source, arguments: arguments),
            filename: script.filename,
            timeout: timeout,
            redirecting: redirects,
            output: output,
        )
    }
}

extension Runtime {
    private static func readScript(
        at path: String,
        delegate: (any Session.Delegate)?,
    ) async throws -> (filename: String, source: String, importDirectory: Path?) {
        let file = try Path(path).file
        guard let delegate else {
            let source = try await FileSystem.shared.withFileHandle(forReadingAt: file) { handle in
                let buffer = try await handle.readToEnd(maximumSizeAllowed: .unlimited)
                return try decodeScript(buffer.readableBytesView)
            }
            return (path, source, try Path(file.removingLastComponent()))
        }

        let target = try await NIOThreadPool.singleton.runIfActive { try FileTarget(file) }
        let request = Session.FileAccessRequest(
            path: target.path,
            operation: .open(mode: .readOnly, options: []),
            exists: target.exists,
        )

        try Task.checkCancellation()
        guard try await delegate.shouldAllowFileAccess(request) else {
            throw Errno.permissionDenied
        }
        try Task.checkCancellation()

        let source = try await NIOThreadPool.singleton.runIfActive {
            try readScript(from: target.openForReading())
        }
        try Task.checkCancellation()
        return (try Path(request.path).string, source, nil)
    }

    private static func readScript(from descriptor: FileDescriptor) throws -> String {
        defer { try? descriptor.close() }
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try unsafe descriptor.read(into: $0) }
            if count == 0 {
                break
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return try decodeScript(bytes)
    }

    private static func decodeScript(_ bytes: some Collection<UInt8>) throws -> String {
        let bomLength = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        guard let source = String(validating: bytes.dropFirst(bomLength), as: UTF8.self) else {
            throw Runtime.Failure("Python script source must be UTF-8.")
        }
        return source
    }

    private func scriptRequirements(_ source: String) async throws -> [String] {
        // Skip the package service for scripts without inline metadata.
        guard source.contains("# /// script") else {
            return []
        }
        return try await withPackageService { service, _, execution in
            try await service.request(
                .script(source: source),
                execution: execution,
            )
        }
    }
}

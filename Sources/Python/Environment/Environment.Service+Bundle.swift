//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import SystemPackage

extension Environment.Service {
    nonisolated func bundle(
        project: Runtime.Path,
        module: String?,
        output: Runtime.Path,
        configuration: Environment.Configuration,
        execution: Session.Control,
    ) async throws {
        let resolution = try await resolveBundleDependencies(
            for: project,
            configuration: configuration,
            execution: execution,
        )

        let files = FileSystem.shared
        let destination = output.file
        let parent = destination.removingLastComponent()
        let archive = Runtime.Paths.bundleStagingFile(
            for: destination,
            identifier: Environment.identifier(),
        )
        defer { try? Environment.unlinkIfPresent(archive) }

        @Sendable
        func stageArchive(in directory: FilePath) async throws {
            let paths = Runtime.Paths.Environment(directory: directory)
            let sitePackages = paths.temporaryPackagesDirectory
            try await Environment.stageFiles(resolution, into: sitePackages, execution: execution)

            if let module {
                let name = try await request(.moduleName(module), execution: execution)
                try await Self.includeModule(
                    name,
                    project: project.file,
                    destination: sitePackages,
                    execution: execution,
                )
            }

            try await files.createDirectory(at: parent, withIntermediateDirectories: true)
            _ = try await request(
                .archive(directory: sitePackages.string, output: archive.string),
                execution: execution,
            )
        }

        try await files.withTemporaryDirectory(prefix: configuration.paths.temporaryDirectory) {
            _, directory in
            try await stageArchive(in: directory)
        }

        try await Self.publishBundle(archive, at: destination, execution: execution)
    }

    private nonisolated func resolveBundleDependencies(
        for project: Runtime.Path,
        configuration: Environment.Configuration,
        execution: Session.Control,
    ) async throws -> Environment.Preparation.Resolution {
        let requirements = try await projectRequirements(at: project, execution: execution)
        let preparation = try await request(
            .prepare(
                requirements: requirements,
                base: configuration.base,
                installed: [:],
                fingerprint: nil,
                update: false,
            ),
            execution: execution,
        )
        guard case let .resolved(resolution) = preparation else {
            throw Runtime.Failure("Expected package files for a new bundle.")
        }
        return resolution
    }

    private static func publishBundle(
        _ archive: FilePath,
        at destination: FilePath,
        execution: Session.Control,
    ) async throws {
        let matchesExisting: Bool
        do {
            matchesExisting = try await Self.archiveMatches(archive, at: destination)
        } catch is FileSystemError {
            matchesExisting = false
        }

        try execution.finishCheckingInterruption()
        if !matchesExisting {
            try Environment.replace(archive, with: destination)
        }
    }

    private static func includeModule(
        _ name: String,
        project: FilePath,
        destination: FilePath,
        execution: Session.Control,
    ) async throws {
        let files = FileSystem.shared
        let package = project.appending(name)
        let filename = name + ".py"
        let source = project.appending(filename)

        if try await files.info(forFileAt: package)?.type == .directory {
            try await copyDirectory(package, to: destination.appending(name), execution: execution)
        } else if try await files.info(forFileAt: source) != nil {
            try await copyProjectFile(source, to: destination.appending(filename))
        } else {
            throw Exception(name: "ModuleNotFoundError", message: name)
        }
    }

    private static func copyDirectory(
        _ source: FilePath,
        to destination: FilePath,
        execution: Session.Control,
    ) async throws {
        for entry in try await projectEntries(in: source) {
            try execution.checkInterruption()
            try await copyProjectEntry(entry, to: destination, execution: execution)
        }
    }

    private static func copyProjectEntry(
        _ entry: DirectoryEntry,
        to destination: FilePath,
        execution: Session.Control,
    ) async throws {
        let files = FileSystem.shared
        let source = entry.path
        guard let info = try await files.info(forFileAt: source) else {
            throw Exception(name: "FileNotFoundError", message: source.string)
        }

        let name = entry.name.string
        let target = destination.appending(entry.name)
        if info.type == .directory {
            // A directory link can escape the project tree or form a cycle.
            let link = try await files.info(forFileAt: source, infoAboutSymbolicLink: true)
            guard link?.type != .symlink else {
                return
            }
            try await copyDirectory(source, to: target, execution: execution)
        } else if !name.hasSuffix(".pyc") && !name.hasSuffix(".pyo") {
            try await copyProjectFile(source, to: target)
        }
    }

    private static func projectEntries(in directory: FilePath) async throws -> [DirectoryEntry] {
        try await FileSystem.shared.withDirectoryHandle(atPath: directory) { handle in
            var entries = [DirectoryEntry]()
            for try await entry in handle.listContents() {
                let name = entry.name.string
                if !name.hasPrefix("."), name != "__pycache__" {
                    entries.append(entry)
                }
            }
            entries.sort { $0.name.string < $1.name.string }
            return entries
        }
    }

    private static func copyProjectFile(_ source: FilePath, to target: FilePath) async throws {
        let files = FileSystem.shared
        try await files.createDirectory(
            at: target.removingLastComponent(),
            withIntermediateDirectories: true,
        )
        do {
            try await files.copyItem(at: Environment.resolvedPath(source), to: target)
        } catch let error as FileSystemError where error.code == .fileAlreadyExists {
            throw Exception(
                name: "ValueError",
                message: "Project module collides with a dependency: \(target)",
            )
        }
    }

    private static func archiveMatches(
        _ archive: FilePath,
        at destination: FilePath,
    ) async throws -> Bool {
        let files = FileSystem.shared
        let existing = try await files.info(forFileAt: destination, infoAboutSymbolicLink: true)
        guard
            let existing,
            existing.type == .regular,
            try await files.info(forFileAt: archive)?.size == existing.size
        else {
            return false
        }
        return try await files.withFileHandle(forReadingAt: archive) { source in
            try await files.withFileHandle(forReadingAt: destination) { target in
                try await Self.contentsMatch(source, target, size: existing.size)
            }
        }
    }

    private static func contentsMatch(
        _ source: ReadFileHandle,
        _ target: ReadFileHandle,
        size: Int64,
    ) async throws -> Bool {
        var offset: Int64 = 0
        while offset < size {
            let length = ByteCount.bytes(min(64 * 1024, size - offset))
            let bytes = try await source.readChunk(fromAbsoluteOffset: offset, length: length)
            let count = bytes.readableBytes
            guard count > 0 else {
                return false
            }

            let existing = try await target.readChunk(fromAbsoluteOffset: offset, length: length)
            guard bytes == existing else {
                return false
            }
            offset += Int64(count)
        }
        return true
    }
}

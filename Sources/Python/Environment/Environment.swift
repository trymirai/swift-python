//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import SystemPackage

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

// MARK: - Environment

// Access is serialized by the Session operation queue. The lease survives interpreter resets.
final class Environment {
    private let directory: Runtime.Path?
    let projectDirectory: Runtime.Path?

    let packaging: Service.Lazy
    let requirements: [String]

    private(set) var manifest: Manifest?

    private var storage: Storage?
    private var temporary: FilePath?

    var needsPreparation: Bool {
        directory != nil || projectDirectory != nil || !requirements.isEmpty
            || !packaging.packages.isEmpty
    }

    var sitePackagesPath: String? {
        guard manifest?.packages.isEmpty == false else {
            return nil
        }
        if let storage {
            return storage.active?.packages(in: storage.root).string
        }
        return temporary?.appending("site-packages").string
    }

    init(
        directory: Runtime.Path?,
        projectDirectory: Runtime.Path?,
        requirements: [String],
        packaging: Service.Lazy,
    ) {
        self.directory = directory
        self.projectDirectory = projectDirectory
        self.requirements = requirements
        self.packaging = packaging
    }

    deinit {
        try? storage?.lease.close()
        if let temporary {
            Task { _ = try? await FileSystem.shared.removeItem(at: temporary) }
        }
    }

    func open(using service: Service, configuration: Configuration) async throws {
        guard let root = directory?.file, storage == nil else {
            return
        }

        let files = FileSystem.shared
        do {
            try await files.createDirectory(at: root, withIntermediateDirectories: true)
        } catch var error as FileSystemError where error.code == .fileAlreadyExists {
            error.code = .invalidArgument
            throw error
        }

        var opened = Storage(root: root, lease: try Self.acquireLease(at: root))
        do {
            let claimed = try Self.isClaimed(opened.lease)
            let publication = try await Self.readPublication(
                in: opened,
                using: service,
                expectedABI: configuration.abi,
            )
            opened.active = publication?.active

            try await Self.prepareSlots(in: opened, claimed: claimed)

            // A new lease can claim the staging paths once they have been checked.
            if !claimed {
                _ = try opened.lease.writeAll(toAbsoluteOffset: 0, [Self.leaseMarker])
            }

            manifest = publication?.manifest
            storage = opened
        } catch {
            try? opened.lease.close()
            throw error
        }
    }

    func installed() async throws -> [String: String] {
        guard needsPreparation || manifest != nil else {
            return [:]
        }
        let (service, configuration) = try await packaging.open()
        try await open(using: service, configuration: configuration)

        let localVersions = manifest?.packages.mapValues(\.version) ?? [:]
        return configuration.baseVersions.merging(localVersions) { _, local in local }
    }

    func save(
        _ next: Manifest,
        replacingFiles resolution: Preparation.Resolution?,
        using service: Service,
        configuration: Configuration,
        execution: Session.Control,
    ) async throws {
        if let storage {
            try await savePersistent(
                next,
                replacingFiles: resolution,
                in: storage,
                using: service,
                configuration: configuration,
                execution: execution,
            )
        } else {
            try await saveTemporary(
                next,
                replacingFiles: resolution,
                configuration: configuration,
                execution: execution,
            )
        }
    }

    private func savePersistent(
        _ next: Manifest,
        replacingFiles resolution: Preparation.Resolution?,
        in storage: Storage,
        using service: Service,
        configuration: Configuration,
        execution: Session.Control,
    ) async throws {
        let active: Slot? = if resolution != nil {
            next.packages.isEmpty ? nil : storage.active?.other ?? .a
        } else {
            storage.active
        }
        guard
            active != nil || storage.active != nil
            || !next.local.isEmpty || manifest?.local.isEmpty == false
        else {
            try execution.finishCheckingInterruption()
            manifest = next
            return
        }

        let staged = resolution == nil ? nil : active?.packages(in: storage.root)
        let stagedManifest = storage.stagedManifestPath
        defer { try? Self.unlinkIfPresent(stagedManifest) }

        func stageManifest() async throws {
            let publication = Publication(active: active, manifest: next)
            let json = try await service.encodePublication(publication)
            try await FileSystem.shared.withFileHandle(
                forWritingAt: stagedManifest,
                options: .newFile(replaceExisting: false, permissions: .ownerReadWrite),
            ) { handle in
                try await handle.write(contentsOf: json.utf8, toAbsoluteOffset: 0)
                try await handle.synchronize()
            }
        }

        try await Self.discardOnFailure(staged) {
            if let staged, let resolution {
                try await FileSystem.shared.removeItem(at: staged)
                try await Self.stageFiles(
                    resolution,
                    into: staged,
                    baseFiles: configuration.baseFiles,
                    execution: execution,
                )
            }

            try await stageManifest()
            try execution.finishCheckingInterruption()

            // Publishing the manifest switches both the active slot and its package records.
            try Self.replace(stagedManifest, with: storage.manifestPath)
        }

        self.manifest = next
        self.storage?.active = active
        if let previous = storage.active, previous != active {
            await Self.discard(previous.packages(in: storage.root))
        }
    }

    private func saveTemporary(
        _ next: Manifest,
        replacingFiles resolution: Preparation.Resolution?,
        configuration: Configuration,
        execution: Session.Control,
    ) async throws {
        guard let resolution else {
            try execution.finishCheckingInterruption()
            manifest = next
            return
        }

        let staged: FilePath? = if next.packages.isEmpty {
            nil
        } else {
            try await FileSystem.shared.createTemporaryDirectory(
                template: configuration.scratchDirectory.appending("XXXXXXXX"),
            )
        }
        try await Self.discardOnFailure(staged) {
            if let staged {
                try await Self.stageFiles(
                    resolution,
                    into: staged.appending("site-packages"),
                    baseFiles: configuration.baseFiles,
                    execution: execution,
                )
            }
            try execution.finishCheckingInterruption()
        }

        let previous = temporary
        manifest = next
        temporary = staged

        if let previous {
            await Self.discard(previous)
        }
    }

    func close() async {
        if let storage {
            self.storage = nil
            try? storage.lease.close()
        }
        if let temporary {
            self.temporary = nil
            await Self.discard(temporary)
        }
    }

    static func identifier() -> String {
        let value = String(UInt128.random(in: .min ... .max), radix: 16)
        return String(repeating: "0", count: 32 - value.utf8.count) + value
    }

    static func replace(_ source: FilePath, with target: FilePath) throws {
        // Readers see either the previous file or its completed replacement.
        try unsafe source.withPlatformString { source in
            try unsafe target.withPlatformString { target in
                guard unsafe rename(source, target) == 0 else {
                    throw Errno(rawValue: errno)
                }
            }
        }
    }

    static func resolvedPath(_ path: FilePath) throws -> FilePath {
        try unsafe path.withPlatformString { path in
            guard let resolved = unsafe realpath(path, nil) else {
                throw Errno(rawValue: errno)
            }
            defer { unsafe free(resolved) }
            return unsafe FilePath(platformString: resolved)
        }
    }

    static func unlinkIfPresent(_ path: FilePath) throws {
        try unsafe path.withPlatformString { path in
            guard unsafe unlink(path) == 0 || errno == ENOENT else {
                throw Errno(rawValue: errno)
            }
        }
    }
}

private extension Environment {
    struct Storage {
        let root: FilePath
        let lease: FileDescriptor
        var active: Slot?

        var manifestPath: FilePath {
            root.appending("environment.json")
        }

        var stagedManifestPath: FilePath {
            root.appending(".environment.json.tmp")
        }
    }

    static func readPublication(
        in storage: Storage,
        using service: Service,
        expectedABI: [String],
    ) async throws -> Publication? {
        let files = FileSystem.shared
        let path = storage.manifestPath
        guard let info = try await files.info(forFileAt: path, infoAboutSymbolicLink: true) else {
            return nil
        }
        guard info.type == .regular else {
            throw invalid("Expected a regular package environment manifest: \(path)")
        }

        let bytes = try await [UInt8](contentsOf: path, maximumSizeAllowed: .unlimited)
        let publication = try await service.decodePublication(bytes)
        guard publication.manifest.abi == expectedABI else {
            throw invalid("The environment was prepared for a different Python runtime")
        }

        if let active = publication.active {
            let packages = active.packages(in: storage.root)
            let info = try await files.info(forFileAt: packages, infoAboutSymbolicLink: true)
            guard info?.type == .directory else {
                throw invalid("The active package directory is missing or invalid")
            }
        }
        return publication
    }

    static func prepareSlots(in storage: Storage, claimed: Bool) async throws {
        let files = FileSystem.shared
        let stagingPaths = Slot.allCases
            .filter { $0 != storage.active }
            .map { $0.packages(in: storage.root) } + [storage.stagedManifestPath]

        // Only a marked root owns the inactive slot and temporary manifest.
        for path in stagingPaths {
            if claimed {
                _ = try? await files.removeItem(at: path)
            } else if try await files.info(forFileAt: path, infoAboutSymbolicLink: true) != nil {
                throw invalid("Reserved package environment path is occupied: \(path)")
            }
        }
    }

    static func discard(_ path: FilePath) async {
        // Cleanup must finish even if the operation was cancelled.
        _ = await Task { try? await FileSystem.shared.removeItem(at: path) }.value
    }

    static func discardOnFailure(
        _ staged: FilePath?,
        _ operation: () async throws -> Void,
    ) async throws {
        do {
            try await operation()
        } catch {
            if let staged {
                await discard(staged)
            }
            throw error
        }
    }

    static func invalid(_ message: String) -> Exception {
        Exception(name: "ValueError", message: message)
    }

    static func isWheelDigest(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8
            .allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    static let leaseMarker: UInt8 = 1

    static func isClaimed(_ lease: FileDescriptor) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 2)
        let count = try bytes.withUnsafeMutableBytes { buffer in
            try unsafe lease.read(fromAbsoluteOffset: 0, into: buffer)
        }

        if count == 0 {
            return false
        }
        guard count == 1, bytes[0] == leaseMarker else {
            throw Self.invalid("Unrecognized package environment lock")
        }
        return true
    }

    static func acquireLease(at root: FilePath) throws -> FileDescriptor {
        let descriptor = try FileDescriptor.open(
            root.appending("environment.lock"),
            .readWrite,
            options: [.create, .closeOnExec, .noFollow],
            permissions: .ownerReadWrite,
        )
        guard flock(descriptor.rawValue, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            try? descriptor.close()
            if code == EWOULDBLOCK || code == EAGAIN {
                throw Exception(
                    name: "RuntimeError",
                    message: "The package environment is already in use: \(root)",
                )
            }
            throw Errno(rawValue: code)
        }
        return descriptor
    }
}

private extension Environment.Slot {
    func packages(in root: FilePath) -> FilePath {
        root.appending("site-packages-" + rawValue)
    }
}

extension Environment {
    static func clearCache(at root: FilePath) async throws {
        let files = FileSystem.shared
        for name in ["wheels", "installed"] {
            let directory = root.appending(name)
            guard
                try await files.info(forFileAt: directory, infoAboutSymbolicLink: true)?
                    .type == .directory
            else {
                continue
            }
            try await files.withDirectoryHandle(atPath: directory) { handle in
                for try await entry in handle.listContents() where entry.type == .directory {
                    let artifact = entry.name.string
                    let partial = name == "installed" && artifact.utf8.count == 17
                        && artifact.hasPrefix(".install-")
                    if isWheelDigest(artifact) || partial {
                        try await files.removeItem(at: entry.path)
                    }
                }
            }
        }
    }

    static func validateBaseFiles(
        _ resolution: Preparation.Resolution,
        against baseFiles: Set<FilePath>,
    ) throws {
        guard !baseFiles.isEmpty else {
            return
        }
        for distribution in resolution.distributions.values {
            if let conflict = distribution.files.first(where: { baseFiles.contains($0.path) }) {
                throw invalid(
                    "Local package file conflicts with the application base: \(conflict.path)",
                )
            }
        }
    }

    static func stageFiles(
        _ resolution: Preparation.Resolution,
        into directory: FilePath,
        baseFiles: Set<FilePath>,
        execution: Session.Control,
    ) async throws {
        try validateBaseFiles(resolution, against: baseFiles)
        let files = FileSystem.shared
        try await files.createDirectory(at: directory, withIntermediateDirectories: true)

        var created = Set([directory])
        func stageMember(_ relative: FilePath, from origin: FilePath) async throws {
            try execution.checkInterruption()
            let source = origin.pushing(relative)
            let target = directory.pushing(relative)
            let parent = target.removingLastComponent()
            if created.insert(parent).inserted {
                try await files.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            guard let error = hardLink(source, to: target) else {
                return
            }

            switch error {
            case .improperLink:
                // A cache and its environment can live on different volumes.
                do {
                    try await files.copyItem(at: source, to: target)
                    return
                } catch let error as FileSystemError where error.code == .fileAlreadyExists {
                    break
                }
            case .fileExists:
                break
            default:
                throw error
            }
            throw invalid("Package file collision: \(relative)")
        }

        for (_, distribution) in resolution.distributions.sorted(by: { $0.key < $1.key }) {
            let origin = distribution.directory.file
            for member in distribution.files {
                try await stageMember(member.path, from: origin)
            }
        }
    }

    private static func hardLink(_ source: FilePath, to target: FilePath) -> Errno? {
        unsafe source.withPlatformString { source in
            unsafe target.withPlatformString { target in
                unsafe link(source, target) == 0 ? nil : Errno(rawValue: errno)
            }
        }
    }
}

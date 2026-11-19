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

// The owning session serializes access after preparation. The lease survives interpreter resets.
final class Environment {
    private let directory: Runtime.Path?
    let projectDirectory: Runtime.Path?
    let requirements: [String]

    private let packaging: Service.Lazy
    private(set) var sessionPackages: [Runtime.PackageSource.Resolved]
    private var sessionConfiguration: Configuration?

    private var storage: Storage?
    private var temporary: FilePath?
    private(set) var manifest: Manifest?

    var needsPreparation: Bool {
        directory != nil || projectDirectory != nil || !requirements.isEmpty
            || !sessionPackages.isEmpty || !packaging.packages.isEmpty
    }

    var packageSources: [Runtime.PackageSource.Resolved] {
        sessionPackages.isEmpty ? packaging.packages : sessionPackages + packaging.packages
    }

    var paths: Runtime.Paths.Environment? {
        storage?.paths
            ?? (directory?.file ?? temporary).map { Runtime.Paths.Environment(directory: $0) }
    }

    var sitePackagesDirectory: FilePath? {
        guard manifest?.packages.isEmpty == false else {
            return nil
        }
        if let storage {
            return storage.active.map { storage.paths.packagesDirectory(for: $0) }
        }
        return temporary
            .map { Runtime.Paths.Environment(directory: $0).temporaryPackagesDirectory }
    }

    init(
        directory: Runtime.Path?,
        projectDirectory: Runtime.Path?,
        requirements: [String],
        sessionPackages: [Runtime.PackageSource.Resolved],
        packaging: Service.Lazy,
    ) {
        self.directory = directory
        self.projectDirectory = projectDirectory
        self.requirements = requirements

        self.sessionPackages = sessionPackages
        self.packaging = packaging
    }

    deinit {
        try? storage?.lease.close()
        if let temporary {
            _ = Self.startDiscarding(temporary)
        }
    }

    func open() async throws -> (Service, Configuration) {
        let (service, application) = try await packaging.open()
        let configuration = try await resolveConfiguration(using: service, application: application)

        if let root = directory?.file, storage == nil {
            let (storage, manifest) = try await Self.openStorage(
                at: root,
                using: service,
                expectedABI: configuration.abi,
            )
            self.manifest = manifest
            self.storage = storage
        }
        return (service, configuration)
    }

    func installed() async throws -> [String: String] {
        guard needsPreparation || manifest != nil else {
            return [:]
        }
        let (_, configuration) = try await open()

        let localVersions = manifest?.packages.mapValues(\.version) ?? [:]
        return configuration.base.mapValues(\.version).merging(localVersions) { _, local in local }
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

    private func resolveConfiguration(
        using service: Service,
        application: Configuration,
    ) async throws -> Configuration {
        if let sessionConfiguration {
            return sessionConfiguration
        }

        if
            sessionPackages.isEmpty, let projectDirectory,
            let source = try await service.projectPackageSource(at: projectDirectory)
        {
            sessionPackages = [source]
        }

        let configuration = if sessionPackages.isEmpty {
            application
        } else {
            try await service.configuration(for: packageSources)
        }
        sessionConfiguration = configuration
        return configuration
    }
}

// MARK: Environment + Package publication

extension Environment {
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
        execution: Session.Control,
    ) async throws {
        let previousSlot = storage.active
        let nextSlot: Slot? = if resolution == nil {
            previousSlot
        } else if next.packages.isEmpty {
            nil
        } else {
            previousSlot?.other ?? .a
        }

        let hasSlot = nextSlot != nil || previousSlot != nil
        let hasLocalRequirements = !next.local.isEmpty || manifest?.local.isEmpty == false
        // A removal still has to publish if it clears the last slot or local requirement.
        guard hasSlot || hasLocalRequirements else {
            try saveManifestInMemory(next, execution: execution)
            return
        }

        let paths = storage.paths
        let stagedPackages: FilePath? = if resolution != nil, let nextSlot {
            paths.packagesDirectory(for: nextSlot)
        } else {
            nil
        }
        let stagedManifest = paths.stagedManifestFile
        defer { try? Self.unlinkIfPresent(stagedManifest) }

        func stageAndPublish() async throws {
            if let stagedPackages, let resolution {
                try await FileSystem.shared.removeItem(at: stagedPackages)
                try await Self.stageFiles(resolution, into: stagedPackages, execution: execution)
            }

            try await Self.publishManifest(
                Publication(active: nextSlot, manifest: next),
                stagingAt: stagedManifest,
                to: paths.manifestFile,
                using: service,
                execution: execution,
            )
        }

        try await Self.discardOnFailure(stagedPackages, stageAndPublish)

        self.manifest = next
        self.storage?.active = nextSlot

        if let previousSlot, previousSlot != nextSlot {
            await Self.discard(paths.packagesDirectory(for: previousSlot))
        }
    }

    private func saveTemporary(
        _ next: Manifest,
        replacingFiles resolution: Preparation.Resolution?,
        configuration: Configuration,
        execution: Session.Control,
    ) async throws {
        guard let resolution else {
            try saveManifestInMemory(next, execution: execution)
            return
        }

        let staged: FilePath? = if next.packages.isEmpty {
            nil
        } else {
            try await FileSystem.shared.createTemporaryDirectory(
                template: configuration.paths.temporaryDirectoryTemplate,
            )
        }

        try await Self.discardOnFailure(staged) {
            if let staged {
                let paths = Runtime.Paths.Environment(directory: staged)
                try await Self.stageFiles(
                    resolution,
                    into: paths.temporaryPackagesDirectory,
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

    private func saveManifestInMemory(_ next: Manifest, execution: Session.Control) throws {
        try execution.finishCheckingInterruption()
        manifest = next
    }
}

// MARK: Environment + Filesystem operations

extension Environment {
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

    private static func invalid(_ message: String) -> Exception {
        Exception(name: "ValueError", message: message)
    }
}

// MARK: Environment.Storage

private extension Environment {
    struct Storage {
        let paths: Runtime.Paths.Environment
        let lease: FileDescriptor

        var active: Slot?
    }
}

// MARK: Environment + Persistent storage

extension Environment {
    private static func openStorage(
        at root: FilePath,
        using service: Service,
        expectedABI: [String],
    ) async throws -> (storage: Storage, manifest: Manifest?) {
        try await createStorageDirectory(at: root)

        let paths = Runtime.Paths.Environment(directory: root)
        var opened = Storage(paths: paths, lease: try acquireLease(at: paths.lockFile, for: root))
        do {
            let claimed = try isClaimed(opened.lease)
            let publication = try await readPublication(
                in: paths,
                using: service,
                expectedABI: expectedABI,
            )
            opened.active = publication?.active
            try await prepareSlots(in: opened, claimed: claimed)

            if !claimed {
                // Claim the root only after confirming the reserved paths are available.
                _ = try opened.lease.writeAll(toAbsoluteOffset: 0, [leaseMarker])
            }
            return (opened, publication?.manifest)
        } catch {
            try? opened.lease.close()
            throw error
        }
    }

    static func createStorageDirectory(at root: FilePath) async throws {
        do {
            try await FileSystem.shared.createDirectory(at: root, withIntermediateDirectories: true)
        } catch var error as FileSystemError where error.code == .fileAlreadyExists {
            error.code = .invalidArgument
            throw error
        }
    }

    static func publishManifest(
        _ manifest: some Encodable & Sendable,
        stagingAt staged: FilePath,
        to target: FilePath,
        using service: Service,
        execution: Session.Control,
    ) async throws {
        try await writeManifest(manifest, to: staged, using: service)

        // Finish interruption checks before the rename makes the new state visible.
        try execution.finishCheckingInterruption()
        try replace(staged, with: target)
    }

    private static func writeManifest(
        _ manifest: some Encodable & Sendable,
        to path: FilePath,
        using service: Service,
    ) async throws {
        let json = try await service.encodeManifest(manifest)
        try await FileSystem.shared.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false, permissions: .ownerReadWrite),
        ) { handle in
            try await handle.write(contentsOf: json.utf8, toAbsoluteOffset: 0)
            try await handle.synchronize()
        }
    }

    private static func readPublication(
        in paths: Runtime.Paths.Environment,
        using service: Service,
        expectedABI: [String],
    ) async throws -> Publication? {
        guard
            let publication = try await readManifest(
                at: paths.manifestFile,
                using: service,
                as: Publication.self,
            )
        else {
            return nil
        }
        try await validatePublication(publication, in: paths, expectedABI: expectedABI)
        return publication
    }

    static func readManifest<Value: Decodable & Sendable>(
        at path: FilePath,
        using service: Service,
        as type: Value.Type,
    ) async throws -> Value? {
        guard
            let info = try await FileSystem.shared.info(
                forFileAt: path,
                infoAboutSymbolicLink: true,
            )
        else {
            return nil
        }
        guard info.type == .regular else {
            throw invalid("Expected a regular package environment manifest: \(path)")
        }
        let bytes = try await [UInt8](contentsOf: path, maximumSizeAllowed: .unlimited)
        return try await service.decodeManifest(bytes, as: type)
    }

    private static func validatePublication(
        _ publication: Publication,
        in paths: Runtime.Paths.Environment,
        expectedABI: [String],
    ) async throws {
        guard publication.manifest.abi == expectedABI else {
            throw invalid("The environment was prepared for a different Python runtime")
        }

        guard let active = publication.active else {
            return
        }
        let packages = paths.packagesDirectory(for: active)
        let info = try await FileSystem.shared.info(
            forFileAt: packages,
            infoAboutSymbolicLink: true,
        )
        guard info?.type == .directory else {
            throw invalid("The active package directory is missing or invalid")
        }
    }

    private static func prepareSlots(in storage: Storage, claimed: Bool) async throws {
        let files = FileSystem.shared
        let inactivePackages = Slot.allCases
            .filter { $0 != storage.active }
            .map { storage.paths.packagesDirectory(for: $0) }

        // The lease marker allows cleanup of files left by a previous writer.
        for path in inactivePackages + [storage.paths.stagedManifestFile] {
            if claimed {
                _ = try? await files.removeItem(at: path)
            } else if try await files.info(forFileAt: path, infoAboutSymbolicLink: true) != nil {
                throw invalid("Reserved package environment path is occupied: \(path)")
            }
        }
    }
}

// MARK: Environment + Staging cleanup

extension Environment {
    static func discard(_ path: FilePath) async {
        await startDiscarding(path).value
    }

    private static func startDiscarding(_ path: FilePath) -> Task<Void, Never> {
        // Cleanup can outlive a cancelled operation or the environment's deinit.
        Task { _ = try? await FileSystem.shared.removeItem(at: path) }
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
}

// MARK: Environment + Exclusive lease

private extension Environment {
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

    static func acquireLease(at lock: FilePath, for root: FilePath) throws -> FileDescriptor {
        let descriptor = try FileDescriptor.open(
            lock,
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

// MARK: - Cache and file staging

extension Environment {
    static func clearCache(at root: FilePath) async throws {
        let paths = Runtime.Paths(cacheDirectory: root)
        try await clearCacheArtifacts(in: paths.wheelsDirectory, removesPartialInstalls: false)
        try await clearCacheArtifacts(in: paths.environmentsDirectory, removesPartialInstalls: true)
    }

    private static func clearCacheArtifacts(
        in directory: FilePath,
        removesPartialInstalls: Bool,
    ) async throws {
        let files = FileSystem.shared
        let info = try await files.info(forFileAt: directory, infoAboutSymbolicLink: true)
        guard info?.type == .directory else {
            return
        }

        try await files.withDirectoryHandle(atPath: directory) { handle in
            for try await entry in handle.listContents() where entry.type == .directory {
                let artifact = entry.name.string
                let partial = removesPartialInstalls && isPartialInstallation(artifact)
                if isCacheDigest(artifact) || partial {
                    try await files.removeItem(at: entry.path)
                }
            }
        }
    }

    private static func isPartialInstallation(_ name: String) -> Bool {
        let prefix = Runtime.Paths.installationPrefix
        let suffix = name.dropFirst(prefix.count)
        return name.hasPrefix(prefix) && suffix.utf8.count == 32
            && suffix.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    private static func isCacheDigest(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8
            .allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    static func stageFiles(
        _ resolution: Preparation.Resolution,
        into directory: FilePath,
        execution: Session.Control,
    ) async throws {
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

            try await linkOrCopyMember(source, to: target, relative: relative)
        }

        let distributions = resolution.distributions.sorted { left, right in left.key < right.key }
        for (_, distribution) in distributions {
            let origin = distribution.directory.file
            for member in distribution.files {
                try await stageMember(member.path, from: origin)
            }
        }
    }

    private static func linkOrCopyMember(
        _ source: FilePath,
        to target: FilePath,
        relative: FilePath,
    ) async throws {
        guard let error = hardLink(source, to: target) else {
            return
        }

        switch error {
        case .improperLink:
            // A cache and its environment can live on different volumes.
            do {
                try await FileSystem.shared.copyItem(at: source, to: target)
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

    private static func hardLink(_ source: FilePath, to target: FilePath) -> Errno? {
        unsafe source.withPlatformString { source in
            unsafe target.withPlatformString { target in
                unsafe link(source, target) == 0 ? nil : Errno(rawValue: errno)
            }
        }
    }
}

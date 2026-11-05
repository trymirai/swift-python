//
//  Created by Anton Spivak
//

internal import Foundation
internal import SystemPackage

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

// MARK: - EnvironmentStore

// Owned by a Session reservation. Its lease outlives interpreter resets.
final class EnvironmentStore {
    let root: String
    let configuration: PackageConfiguration
    private let isTemporary: Bool
    private var lockDescriptor: FileDescriptor?
    private(set) var generation: String?
    private(set) var state: EnvironmentState

    var path: String? {
        generation.map(sitePackagesDirectory(for:))
    }

    private var generationsDirectory: String {
        root + "/generations"
    }

    init(directory: String?, configuration: PackageConfiguration) throws {
        self.configuration = configuration
        isTemporary = directory == nil
        root = directory ?? configuration.cacheDirectory + "/environments/" + Self.identifier()
        state = EnvironmentState(abi: configuration.abi)
        do {
            try Self.createDirectory(generationsDirectory)
            lockDescriptor = try Self.acquireLease(at: root)
            generation = try currentGeneration()
            if let generation {
                state = try readState(for: generation)
            }
            try prune()
        } catch {
            if isTemporary && lockDescriptor == nil {
                try? Self.remove(root)
            }
            try? close()
            throw error
        }
    }

    deinit {
        try? close()
    }

    func installedPackages() -> [String: String] {
        configuration.baseVersions
            .merging(state.packages.mapValues(\.version)) { _, local in local }
    }

    func stage(
        _ preparation: PackagePreparation,
        requirements: [String],
        local: [String: String],
        execution: ExecutionControl,
    ) throws -> Generation {
        let id = Self.identifier()
        let directory = generationDirectory(for: id)
        let sitePackages = sitePackagesDirectory(for: id)
        do {
            try Self.createDirectory(sitePackages)
            var files = [String: [String]]()
            for (name, distribution) in preparation.distributions.sorted(by: { $0.key < $1.key }) {
                try merge(distribution, into: sitePackages, execution: execution)
                files[name] = distribution.files
            }
            let next = EnvironmentState(
                abi: configuration.abi,
                fingerprint: preparation.fingerprint,
                requirements: requirements,
                local: local,
                packages: preparation.distributions.mapValues(\.record),
                files: files,
            )
            try Self.write(next, to: directory + "/environment.json")
            return Generation(
                id: id,
                path: sitePackages,
                state: next,
                changedFiles: changedFiles(in: next),
            )
        } catch {
            try? Self.remove(directory)
            throw error
        }
    }

    func publish(_ next: Generation) throws {
        guard try currentGeneration() == generation else {
            throw Exception(
                name: "RuntimeError",
                message: "The environment changed while packages were being prepared",
            )
        }
        try linkGeneration(next.id)
        generation = next.id
        state = next.state
    }

    func restore(
        generation previous: String?,
        state previousState: EnvironmentState,
        discarding next: String,
    ) throws {
        let current = try currentGeneration()
        if current == next {
            try linkGeneration(previous)
        } else if current != previous {
            throw Exception(
                name: "RuntimeError",
                message: "Cannot restore an environment changed by another writer",
            )
        }
        generation = previous
        state = previousState
    }

    func discard(_ id: String) throws {
        if try currentGeneration() != id {
            try Self.remove(generationDirectory(for: id))
        }
    }

    // Existing modules can retain paths into any earlier generation until reset.
    func importRoots() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: generationsDirectory)
            .filter(Self.isGeneration)
            .map(sitePackagesDirectory(for:))
    }

    func prune() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: generationsDirectory)
            where Self.isGeneration(name) && name != generation
        {
            try Self.remove(generationDirectory(for: name))
        }
    }

    func close() throws {
        guard let descriptor = lockDescriptor else {
            return
        }
        defer {
            lockDescriptor = nil
            try? descriptor.close()
        }
        if isTemporary {
            try Self.remove(root)
        } else {
            try prune()
        }
    }

    static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func replace(_ source: String, with target: String) throws {
        guard unsafe rename(source, target) == 0 else {
            throw Errno(rawValue: errno)
        }
    }
}

// MARK: EnvironmentStore.Generation

extension EnvironmentStore {
    struct Generation {
        let id: String
        let path: String
        let state: EnvironmentState
        let changedFiles: [String]
    }
}

private extension EnvironmentStore {
    static func acquireLease(at root: String) throws -> FileDescriptor {
        let descriptor = try FileDescriptor.open(
            FilePath(root + "/environment.lock"),
            .readWrite,
            options: [.create, .closeOnExec],
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

    func readState(for id: String) throws -> EnvironmentState {
        let manifest = generationDirectory(for: id) + "/environment.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let state = try JSONDecoder().decode(EnvironmentState.self, from: data)
        guard state.abi == configuration.abi else {
            throw Self.invalid("The environment was prepared for a different Python runtime")
        }
        return state
    }

    func generationDirectory(for id: String) -> String {
        generationsDirectory + "/" + id
    }

    func sitePackagesDirectory(for id: String) -> String {
        generationDirectory(for: id) + "/site-packages"
    }

    func changedFiles(in next: EnvironmentState) -> [String] {
        let names = Set(state.packages.keys).union(next.packages.keys)
        var files = Set<FilePath>()
        for name in names where state.packages[name] != next.packages[name] {
            // File identity uses bytes because String equality folds Unicode equivalents.
            for path in state.files[name] ?? [] {
                files.insert(FilePath(path))
            }
            for path in next.files[name] ?? [] {
                files.insert(FilePath(path))
            }
        }
        return files.map(\.string).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func invalid(_ message: String) -> Exception {
        Exception(name: "ValueError", message: message)
    }

    static func isGeneration(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8
            .allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    func currentGeneration() throws -> String? {
        let pointer = root + "/current"
        let target: String
        do {
            target = try FileManager.default.destinationOfSymbolicLink(atPath: pointer)
        } catch {
            if FileManager.default.fileExists(atPath: pointer) {
                throw Self.invalid("The environment's current entry must be a generation link")
            }
            if Self.isMissingFile(error) {
                return nil
            }
            throw error
        }
        let prefix = "generations/"
        let id = String(target.dropFirst(prefix.count))
        guard target.hasPrefix(prefix), Self.isGeneration(id) else {
            throw Self.invalid("Invalid environment generation")
        }
        return id
    }

    func linkGeneration(_ id: String?) throws {
        let pointer = root + "/current"
        guard let id else {
            try Self.remove(pointer)
            return
        }
        let temporaryLink = root + "/.current-" + Self.identifier()
        defer { try? Self.remove(temporaryLink) }
        try FileManager.default.createSymbolicLink(
            atPath: temporaryLink,
            withDestinationPath: "generations/" + id,
        )
        try Self.replace(temporaryLink, with: pointer)
    }

    func merge(
        _ distribution: PreparedDistribution,
        into sitePackagesDirectory: String,
        execution: ExecutionControl,
    ) throws {
        let fileManager = FileManager.default
        let device = try fileManager
            .attributesOfItem(atPath: sitePackagesDirectory)[.systemNumber] as? NSNumber
        for relative in distribution.files {
            try execution.checkInterruption()
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard
                !relative.hasPrefix("/"), !relative.utf8.contains(0),
                parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else {
                throw Self.invalid("Invalid wheel member: \(relative)")
            }
            if configuration.baseFiles.contains(FilePath(relative)) {
                throw Self
                    .invalid("Local package file conflicts with the application base: \(relative)")
            }
            let source = distribution.directory + "/" + relative
            let target = sitePackagesDirectory + "/" + relative
            if fileManager.fileExists(atPath: target) {
                throw Self.invalid("Package file collision: \(relative)")
            }
            try Self.createDirectory(URL(fileURLWithPath: target).deletingLastPathComponent().path)
            let sourceDevice = try fileManager
                .attributesOfItem(atPath: source)[.systemNumber] as? NSNumber
            if sourceDevice == device {
                try fileManager.linkItem(atPath: source, toPath: target)
            } else {
                try fileManager.copyItem(atPath: source, toPath: target)
            }
        }
    }

    static func write(_ state: EnvironmentState, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(10)
        let temporaryPath = path + "." + identifier()
        defer { try? remove(temporaryPath) }
        let descriptor = try FileDescriptor.open(
            FilePath(temporaryPath),
            .writeOnly,
            options: [.create, .exclusiveCreate, .closeOnExec],
            permissions: .ownerReadWrite,
        )
        defer { try? descriptor.close() }
        try descriptor.writeAll(data)
        guard fsync(descriptor.rawValue) == 0 else {
            throw Errno(rawValue: errno)
        }
        try replace(temporaryPath, with: path)
    }

    static func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func remove(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch where isMissingFile(error) {}
    }

    static func isMissingFile(_ error: any Swift.Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }
}

//
//  Created by Anton Spivak
//

public import SystemPackage

// MARK: - Runtime.Paths.Environment

public extension Runtime.Paths {
    /// Paths for an environment or one shared dependency resolution.
    struct Environment: Sendable, Hashable {
        public let directory: FilePath

        public init(directory: FilePath) {
            self.directory = directory.lexicallyNormalized()
        }

        public var manifestFile: FilePath {
            directory.appending("environment.json")
        }

        /// The staging path for writers holding the environment lock.
        public var stagedManifestFile: FilePath {
            directory.appending(".environment.json.tmp")
        }

        /// A writer-specific staging path for shared preparations.
        public func stagedManifestFile(identifier: String) -> FilePath {
            directory.appending(".environment-" + identifier + ".json.tmp")
        }

        public var lockFile: FilePath {
            directory.appending("environment.lock")
        }

        public var temporaryPackagesDirectory: FilePath {
            directory.appending(Runtime.Paths.sitePackagesName)
        }

        public func packagesDirectory(for slot: Slot) -> FilePath {
            directory.appending(Runtime.Paths.sitePackagesName + "-" + slot.rawValue)
        }
    }
}

// MARK: - Runtime.Paths.Environment.Slot

public extension Runtime.Paths.Environment {
    /// Alternating package directories for a persistent session environment.
    enum Slot: String, CaseIterable, Sendable {
        case a
        case b
    }
}

extension Runtime.Paths.Environment.Slot {
    var other: Self {
        self == .a ? .b : .a
    }
}

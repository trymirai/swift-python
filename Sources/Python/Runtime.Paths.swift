//
//  Created by Anton Spivak
//

public import SystemPackage

// MARK: - Runtime.Paths

public extension Runtime {
    /// The directory layout of the shared package cache.
    struct Paths: Sendable, Hashable {
        public let cacheDirectory: FilePath

        public init(cacheDirectory: FilePath) {
            self.cacheDirectory = cacheDirectory.lexicallyNormalized()
        }

        public var wheelsDirectory: FilePath {
            cacheDirectory.appending("wheels")
        }

        public func wheelDirectory(digest: String) -> FilePath {
            wheelsDirectory.appending(digest)
        }

        public func wheelFile(digest: String, filename: String) -> FilePath {
            wheelDirectory(digest: digest).appending(filename)
        }

        public func downloadFile(digest: String, identifier: String) -> FilePath {
            wheelDirectory(digest: digest).appending(identifier + Self.downloadSuffix)
        }

        public func wheelPackagesDirectory(digest: String) -> FilePath {
            wheelDirectory(digest: digest).appending(Self.sitePackagesName)
        }

        public func wheelStagingDirectory(digest: String, identifier: String) -> FilePath {
            wheelDirectory(digest: digest).appending(Self.installationPrefix + identifier)
        }

        public var environmentsDirectory: FilePath {
            cacheDirectory.appending("environments")
        }

        public func environmentDirectory(digest: String) -> FilePath {
            environmentsDirectory.appending(digest)
        }

        public func environmentPackagesDirectory(digest: String) -> FilePath {
            environmentDirectory(digest: digest).appending(Self.sitePackagesName)
        }

        public func environmentStagingDirectory(identifier: String) -> FilePath {
            environmentsDirectory.appending(Self.installationPrefix + identifier)
        }

        public var temporaryDirectory: FilePath {
            cacheDirectory.appending("tmp")
        }

        public var temporaryDirectoryTemplate: FilePath {
            temporaryDirectory.appending("XXXXXXXX")
        }

        public static func preparation(in directory: FilePath, fingerprint: String) -> Environment {
            Environment(directory: directory.appending(fingerprint))
        }

        public static func bundleStagingFile(for output: FilePath, identifier: String) -> FilePath {
            output.removingLastComponent().appending(".bundle-" + identifier)
        }
    }
}

extension Runtime.Paths {
    static let sitePackagesName = "site-packages"
    static let installationPrefix = ".install-"
    static let downloadSuffix = ".download"

    static func defaultPaths(in attachment: borrowing PThread.Attachment) throws -> Self {
        let tempfile = try Object.import(module: "tempfile", in: attachment)
        let temporary = try tempfile(methodNamed: "gettempdir")().string()
        let tag = try Object.import(module: "sys", in: attachment)
            .value(forAttribute: "implementation")
            .value(forAttribute: "cache_tag")
            .string()

        let cache = FilePath(temporary).appending("swift-python-packages").appending(tag)
        return Self(cacheDirectory: cache)
    }
}

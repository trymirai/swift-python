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

        public var installedDirectory: FilePath {
            cacheDirectory.appending("installed")
        }

        public func installationDirectory(digest: String) -> FilePath {
            installedDirectory.appending(digest)
        }

        public func installedPackagesDirectory(digest: String) -> FilePath {
            installationDirectory(digest: digest).appending(Self.sitePackagesName)
        }

        public func installationStagingDirectory(identifier: String) -> FilePath {
            installedDirectory.appending(Self.installationPrefix + identifier)
        }

        public var preparedDirectory: FilePath {
            cacheDirectory.appending("prepared")
        }

        public func preparedInstallationDirectory(digest: String) -> FilePath {
            preparedDirectory.appending(digest)
        }

        public func preparedPackagesDirectory(digest: String) -> FilePath {
            preparedInstallationDirectory(digest: digest).appending(Self.sitePackagesName)
        }

        public func preparedStagingDirectory(identifier: String) -> FilePath {
            preparedDirectory.appending(Self.installationPrefix + identifier)
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
        let temporary = try Object.import(module: "tempfile", in: attachment)
            .attribute("gettempdir")
            .call()
            .string()
        let tag = try Object.import(module: "sys", in: attachment)
            .attribute("implementation")
            .attribute("cache_tag")
            .string()

        let cache = FilePath(temporary).appending("swift-python-packages").appending(tag)
        return Self(cacheDirectory: cache)
    }
}

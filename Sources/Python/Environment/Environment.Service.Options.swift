//
//  Created by Anton Spivak
//

// MARK: - Environment.Service.Options

extension Environment.Service {
    struct Options: Sendable {
        let cacheDirectory: Runtime.Path?
        let packageIndex: String

        func resolved(in attachment: borrowing PThread.Attachment) throws -> ResolvedOptions {
            let paths = if let cacheDirectory {
                Runtime.Paths(cacheDirectory: cacheDirectory.file)
            } else {
                try Runtime.Paths.defaultPaths(in: attachment)
            }
            _ = try Runtime.Path(paths.cacheDirectory)

            return ResolvedOptions(paths: paths, packageIndex: packageIndex)
        }
    }
}

// MARK: - Environment.Service.ResolvedOptions

extension Environment.Service {
    struct ResolvedOptions {
        let paths: Runtime.Paths
        let packageIndex: String
    }
}

// MARK: - Environment.Service.ResolvedOptions + Encodable

extension Environment.Service.ResolvedOptions: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(paths.cacheDirectory.string, forKey: "cache")
        try encoder.encode(paths.wheelsDirectory.string, forKey: "wheels")

        try encoder.encode(Runtime.Paths.sitePackagesName, forKey: "site_packages")
        try encoder.encode(Runtime.Paths.installationPrefix, forKey: "installation_prefix")
        try encoder.encode(Runtime.Paths.downloadSuffix, forKey: "download_suffix")

        try encoder.encode(packageIndex, forKey: "index")
    }
}

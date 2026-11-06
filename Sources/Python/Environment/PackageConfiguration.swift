//
//  Created by Anton Spivak
//

internal import SystemPackage

// MARK: - PackageConfiguration

struct PackageConfiguration: Sendable {
    let cacheDirectory: String
    let abi: [String]
    let baseVersions: [String: String]
    let baseFiles: Set<FilePath>
}

// MARK: Decodable

extension PackageConfiguration: Decodable {
    init(from decoder: borrowing Decoder) throws {
        cacheDirectory = try decoder.decode(String.self, forKey: "cache")
        abi = try decoder.decode([String].self, forKey: "abi")
        baseVersions = try decoder.decode([String: String].self, forKey: "base")
        baseFiles = Set(try decoder.decode([String].self, forKey: "base_files")
            .map { FilePath($0) })
    }
}

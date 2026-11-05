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
        cacheDirectory = try decoder["cache"].get()
        abi = try decoder["abi"].get()
        baseVersions = try decoder["base"].get()
        baseFiles = Set(try decoder["base_files"].get(as: [String].self).map { FilePath($0) })
    }
}

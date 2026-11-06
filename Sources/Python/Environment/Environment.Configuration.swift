//
//  Created by Anton Spivak
//

internal import SystemPackage

// MARK: - Environment.Configuration

extension Environment {
    struct Configuration: Sendable {
        let cacheDirectory: Runtime.Path
        let abi: [String]

        let baseVersions: [String: String]
        let baseFiles: Set<FilePath>

        var scratchDirectory: FilePath {
            cacheDirectory.file.appending("tmp")
        }
    }
}

// MARK: - Environment.Configuration + Decodable

extension Environment.Configuration: Decodable {
    init(from decoder: borrowing Decoder) throws {
        cacheDirectory = try Runtime.Path(decoder.decode(String.self, forKey: "cache"))
        abi = try decoder.decode([String].self, forKey: "abi")

        baseVersions = try decoder.decode([String: String].self, forKey: "base")
        baseFiles = Set(try decoder.decode([String].self, forKey: "base_files")
            .map { FilePath($0) })
    }
}

//
//  Created by Anton Spivak
//

// MARK: - Environment.Configuration

extension Environment {
    struct Configuration: Sendable {
        let paths: Runtime.Paths
        let abi: [String]

        let packageDirectories: [Runtime.Path]
        let base: [String: BasePackage]
    }
}

// MARK: - Environment.BasePackage

extension Environment {
    struct BasePackage: Sendable {
        let version: String
        let requires: [String]
        let files: [String]
    }
}

// MARK: - Environment.Configuration + Decodable

extension Environment.Configuration: Decodable {
    init(from decoder: borrowing Decoder) throws {
        let cache = try Runtime.Path(decoder.decode(String.self, forKey: "cache"))
        paths = Runtime.Paths(cacheDirectory: cache.file)
        abi = try decoder.decode([String].self, forKey: "abi")

        let directories = try decoder.decode([String].self, forKey: "paths")
        packageDirectories = try directories.map(Runtime.Path.init)
        base = try decoder.decode([String: Environment.BasePackage].self, forKey: "base")
    }
}

// MARK: - Environment.BasePackage + Decodable

extension Environment.BasePackage: Decodable {
    init(from decoder: borrowing Decoder) throws {
        version = try decoder.decode(String.self, forKey: "version")
        requires = try decoder.decode([String].self, forKey: "requires")
        files = try decoder.decode([String].self, forKey: "files")
    }
}

// MARK: - Environment.BasePackage + Encodable

extension Environment.BasePackage: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(version, forKey: "version")
        try encoder.encode(requires, forKey: "requires")
        try encoder.encode(files, forKey: "files")
    }
}

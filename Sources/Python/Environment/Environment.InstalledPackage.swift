//
//  Created by Anton Spivak
//

// MARK: - Environment.InstalledPackage

extension Environment {
    struct InstalledPackage: Equatable, Sendable {
        let version: String

        let url: String
        let digest: String
        let filename: String
    }
}

// MARK: - Environment.InstalledPackage + Encodable

extension Environment.InstalledPackage: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(version, forKey: "version")
        try encoder.encode(url, forKey: "url")
        try encoder.encode(digest, forKey: "digest")
        try encoder.encode(filename, forKey: "filename")
    }
}

// MARK: - Environment.InstalledPackage + Decodable

extension Environment.InstalledPackage: Decodable {
    init(from decoder: borrowing Decoder) throws {
        version = try decoder.decode(String.self, forKey: "version")
        url = try decoder.decode(String.self, forKey: "url")
        digest = try decoder.decode(String.self, forKey: "digest")
        filename = try decoder.decode(String.self, forKey: "filename")
    }
}

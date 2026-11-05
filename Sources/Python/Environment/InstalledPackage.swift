//
//  Created by Anton Spivak
//

// MARK: - InstalledPackage

struct InstalledPackage: Swift.Codable, Equatable, Sendable {
    let version: String
    let url: String
    let digest: String
    let filename: String
}

// MARK: Encodable

extension InstalledPackage: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(version, forKey: "version")
        try encoder.encode(url, forKey: "url")
        try encoder.encode(digest, forKey: "digest")
        try encoder.encode(filename, forKey: "filename")
    }
}

// MARK: Decodable

extension InstalledPackage: Decodable {
    init(from decoder: borrowing Decoder) throws {
        version = try decoder["version"].get()
        url = try decoder["url"].get()
        digest = try decoder["digest"].get()
        filename = try decoder["filename"].get()
    }
}

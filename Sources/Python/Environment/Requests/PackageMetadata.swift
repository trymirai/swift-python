//
//  Created by Anton Spivak
//

// MARK: - PackageMetadata

struct PackageMetadata {
    let value: PackageSource
}

// MARK: Encodable

extension PackageMetadata: Encodable {
    func encode(to encoder: inout Encoder) throws {
        switch value {
        case let .directory(path):
            try encoder.encode(path, forKey: "directory")
        case let .archive(path):
            try encoder.encode(path, forKey: "archive")
        case let .embedded(bytes):
            try encoder.encode(bytes.count, forKey: "size")
        }
    }
}

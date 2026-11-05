//
//  Created by Anton Spivak
//

// MARK: - ServiceConfiguration

struct ServiceConfiguration: Sendable {
    let cacheDirectory: String?
    let packageIndex: String
}

// MARK: Encodable

extension ServiceConfiguration: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(cacheDirectory, forKey: "cache")
        try encoder.encode(packageIndex, forKey: "index")
    }
}

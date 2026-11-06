//
//  Created by Anton Spivak
//

// MARK: - Environment.Service.Options

extension Environment.Service {
    struct Options: Sendable {
        let cacheDirectory: Runtime.Path?
        let packageIndex: String
    }
}

// MARK: - Environment.Service.Options + Encodable

extension Environment.Service.Options: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(cacheDirectory?.string, forKey: "cache")
        try encoder.encode(packageIndex, forKey: "index")
    }
}

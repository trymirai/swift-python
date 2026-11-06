//
//  Created by Anton Spivak
//

struct PackagePreparation: Decodable, Sendable {
    let fingerprint: String
    let isUnchanged: Bool
    let distributions: [String: PreparedDistribution]

    init(from decoder: borrowing Decoder) throws {
        fingerprint = try decoder.decode(String.self, forKey: "fingerprint")
        isUnchanged = try decoder.decode(Bool.self, forKey: "unchanged")
        distributions = try decoder.decode(
            [String: PreparedDistribution].self,
            forKey: "distributions",
        )
    }
}

//
//  Created by Anton Spivak
//

struct PackagePreparation: Decodable, Sendable {
    let fingerprint: String
    let isUnchanged: Bool
    let distributions: [String: PreparedDistribution]

    init(from decoder: borrowing Decoder) throws {
        fingerprint = try decoder["fingerprint"].get()
        isUnchanged = try decoder["unchanged"].get()
        distributions = try decoder["distributions"].get()
    }
}

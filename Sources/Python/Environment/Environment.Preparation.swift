//
//  Created by Anton Spivak
//

// MARK: - Environment.Preparation

extension Environment {
    enum Preparation: Decodable, Sendable {
        case unchanged
        case requiresReset
        case resolved(Resolution)

        init(from decoder: borrowing Decoder) throws {
            switch try decoder.decode(String.self, forKey: "status") {
            case "unchanged":
                self = .unchanged
            case "requires_reset":
                self = .requiresReset
            case "resolved":
                self = try .resolved(Resolution(
                    fingerprint: decoder.decode(String.self, forKey: "fingerprint"),
                    distributions: decoder.decode(
                        [String: Distribution].self,
                        forKey: "distributions",
                    ),
                ))
            default:
                throw decoder.mismatch("package preparation status")
            }
        }
    }
}

// MARK: - Environment.Preparation.Resolution

extension Environment.Preparation {
    struct Resolution: Sendable {
        let fingerprint: String
        let distributions: [String: Distribution]
    }
}

//
//  Created by Anton Spivak
//

// MARK: - ServiceAcknowledgement

struct ServiceAcknowledgement: Sendable {}

// MARK: Decodable

extension ServiceAcknowledgement: Decodable {
    init(from decoder: borrowing Decoder) throws {}
}

//
//  Created by Anton Spivak
//

// MARK: - String + Encodable

extension String: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        try encoder.encode(self)
    }
}

// MARK: - String + Decodable

extension String: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        self = try decoder.string()
    }
}

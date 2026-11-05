//
//  Created by Anton Spivak
//

// MARK: - Bool + Encodable

extension Bool: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        try encoder.encode(self)
    }
}

// MARK: - Bool + Decodable

extension Bool: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        self = try decoder.bool()
    }
}

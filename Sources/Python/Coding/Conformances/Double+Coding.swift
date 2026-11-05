//
//  Created by Anton Spivak
//

// MARK: - Double + Encodable

extension Double: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        try encoder.encode(self)
    }
}

// MARK: - Double + Decodable

extension Double: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        self = try decoder.double()
    }
}

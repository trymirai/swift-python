//
//  Created by Anton Spivak
//

// MARK: - Optional + Encodable

extension Optional: Encodable where Wrapped: Encodable & ~Copyable {
    public func encode(to encoder: inout Encoder) throws {
        switch self {
        case .none:
            try encoder.encodeNil()
        case let .some(value):
            try value.encode(to: &encoder)
        }
    }
}

// MARK: - Optional + Decodable

extension Optional: Decodable where Wrapped: Decodable & ~Copyable {
    public init(from decoder: borrowing Decoder) throws {
        self = decoder.isNone ? nil : try decoder.decode(Wrapped.self)
    }
}

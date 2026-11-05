//
//  Created by Anton Spivak
//

public extension Encodable where Self: FixedWidthInteger {
    borrowing func encode(to encoder: inout Encoder) throws {
        try encoder.encodeInteger(copy self)
    }
}

public extension Decodable where Self: FixedWidthInteger {
    init(from decoder: borrowing Decoder) throws {
        self = try decoder.integer()
    }
}

// MARK: - Int + Encodable, Decodable

extension Int: Encodable, Decodable {}

// MARK: - Int8 + Encodable, Decodable

extension Int8: Encodable, Decodable {}

// MARK: - Int16 + Encodable, Decodable

extension Int16: Encodable, Decodable {}

// MARK: - Int32 + Encodable, Decodable

extension Int32: Encodable, Decodable {}

// MARK: - Int64 + Encodable, Decodable

extension Int64: Encodable, Decodable {}

// MARK: - Int128 + Encodable, Decodable

extension Int128: Encodable, Decodable {}

// MARK: - UInt + Encodable, Decodable

extension UInt: Encodable, Decodable {}

// MARK: - UInt8 + Encodable, Decodable

extension UInt8: Encodable, Decodable {}

// MARK: - UInt16 + Encodable, Decodable

extension UInt16: Encodable, Decodable {}

// MARK: - UInt32 + Encodable, Decodable

extension UInt32: Encodable, Decodable {}

// MARK: - UInt64 + Encodable, Decodable

extension UInt64: Encodable, Decodable {}

// MARK: - UInt128 + Encodable, Decodable

extension UInt128: Encodable, Decodable {}

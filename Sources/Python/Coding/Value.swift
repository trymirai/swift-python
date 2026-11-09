//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Value

/// Copied Python scalars and containers that can outlive the interpreter.
public enum Value: Sendable {
    case none
    case bool(Bool)
    case integer(Int64)
    case float(Double)
    case string(String)
    case bytes([UInt8])
    case list([Value])
    case dictionary([String: Value])
}

// MARK: Encodable

extension Value: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        switch self {
        case .none:
            try encoder.encodeNil()
        case let .bool(value):
            try encoder.encode(value)
        case let .integer(value):
            try encoder.encodeInteger(value)
        case let .float(value):
            try encoder.encode(value)
        case let .string(value):
            try encoder.encode(value)
        case let .bytes(value):
            try encoder.encodeBytes(value.span)
        case let .list(value):
            try encoder.encode(value)
        case let .dictionary(value):
            try encoder.encode(value)
        }
    }
}

// MARK: Decodable

extension Value: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        let object = try decoder.object()
        self = try object.value(depth: decoder.depth)
    }
}

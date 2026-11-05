//
//  Created by Anton Spivak
//

// MARK: - Float + Encodable

extension Float: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        try encoder.encode(Double(self))
    }
}

// MARK: - Float + Decodable

extension Float: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        let value = try decoder.double()
        let converted = Float(value)
        guard !value.isFinite || converted.isFinite else {
            throw Exception(
                name: "OverflowError",
                message: "Python float does not fit Float.",
            )
        }
        self = converted
    }
}

//
//  Created by Anton Spivak
//

// MARK: - Dictionary + Encodable

extension Dictionary: Encodable where Key == String, Value: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        try encoder.encode(self)
    }
}

// MARK: - Dictionary + Decodable

extension Dictionary: Decodable where Key == String, Value: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        self.init()
        for key in try decoder.keys() {
            self[key] = try decoder.decode(Value.self, forKey: key)
        }
    }
}

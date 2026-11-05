//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Array + Encodable

extension Array: Encodable where Element: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        try encoder.encode(self)
    }
}

// MARK: - Array + Decodable

extension Array: Decodable where Element: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        guard unsafe CPython_ValueTypeOf(decoder.pointer) == CPython_ValueSequence else {
            throw decoder.mismatch("list or tuple")
        }
        let count = try decoder.count
        self.init()
        reserveCapacity(count)
        for index in 0 ..< count {
            append(try decoder[index].get(as: Element.self))
        }
    }
}

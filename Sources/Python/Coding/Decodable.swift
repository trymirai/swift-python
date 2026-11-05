//
//  Created by Anton Spivak
//

// MARK: - Decodable

/// Decodes a scoped Python value into Swift.
public protocol Decodable: ~Copyable {
    init(from decoder: borrowing Decoder) throws
}

extension Decodable where Self: ~Copyable {
    // Class conformances delegate here to reuse the instance held by the Python wrapper.
    init(existing value: consuming Self) {
        self = value
    }
}

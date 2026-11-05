//
//  Created by Anton Spivak
//

/// Writes a Swift value into the current Python interpreter.
public protocol Encodable: ~Copyable {
    borrowing func encode(to encoder: inout Encoder) throws
}

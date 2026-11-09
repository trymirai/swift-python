//
//  Created by Anton Spivak
//

/// Produces one Python value in the supplied encoder.
public protocol Encodable: ~Copyable {
    borrowing func encode(to encoder: inout Encoder) throws
}

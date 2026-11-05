//
//  Created by Anton Spivak
//

struct CallbackResult: Sendable {
    let encode: @Sendable (inout Encoder) throws -> Void

    init<Value: Encodable & Sendable>(_ value: Value) {
        encode = { encoder in try value.encode(to: &encoder) }
    }
}

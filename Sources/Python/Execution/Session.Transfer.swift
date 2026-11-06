//
//  Created by Anton Spivak
//

import Synchronization

extension Session {
    // The selected Swift 6.4 cancellation handler requires a Copyable return value.
    // This single-use box transports an owned result without making it Copyable.
    final class Transfer<Value: Sendable & ~Copyable>: Sendable {
        private let value: Mutex<Value?>

        init(_ value: consuming Value) {
            self.value = Mutex(consume value)
        }

        func take() -> Value {
            guard let result = value.withLock({ exchange(&$0, with: nil) }) else {
                preconditionFailure("A Python result can only be taken once.")
            }
            return result
        }
    }
}

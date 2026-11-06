//
//  Created by Anton Spivak
//

extension Arguments {
    struct PreparedSpan<Element: BitwiseCopyable>: ~Copyable, ~Escapable, _PArgument {
        private var lease: PreparedValue<BufferLease<Element>>

        @_lifetime(copy lease)
        init(_ lease: consuming PreparedValue<BufferLease<Element>>) {
            self.lease = lease
        }

        borrowing func validate() throws {
            try lease.validate()
        }

        mutating func withValue<Result: ~Copyable>(
            _ body: (inout Span<Element>) throws -> Result,
        ) throws -> Result {
            try lease.withValue {
                try $0.withSpan { span in
                    var span = span
                    return try body(&span)
                }
            }
        }
    }
}

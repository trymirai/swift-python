//
//  Created by Anton Spivak
//

extension Arguments {
    struct PreparedMutableSpan<Element: BitwiseCopyable>: ~Copyable, ~Escapable, _PArgument {
        private var lease: PreparedValue<BufferLease<Element>.Mutable>

        @_lifetime(copy lease)
        init(_ lease: consuming PreparedValue<BufferLease<Element>.Mutable>) {
            self.lease = lease
        }

        borrowing func validate() throws {
            try lease.validate()
        }

        mutating func withValue<Result: ~Copyable>(
            _ body: (inout MutableSpan<Element>) throws -> Result,
        ) throws -> Result {
            try lease.withValue {
                try $0.withMutableSpan(body)
            }
        }
    }
}

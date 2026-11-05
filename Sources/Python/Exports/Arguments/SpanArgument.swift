//
//  Created by Anton Spivak
//

struct SpanArgument<Element: BitwiseCopyable>: ~Copyable, ~Escapable, _PythonArgument {
    let lease: BufferLease<Element>?
    let error: (any Swift.Error)?

    @_lifetime(copy lease)
    init(lease: consuming BufferLease<Element>?, error: (any Swift.Error)?) {
        self.lease = consume lease
        self.error = error
    }

    mutating func validate() throws {
        if let error {
            throw error
        }
    }

    mutating func withValue<Result: ~Copyable>(
        _ body: (inout Span<Element>) throws -> Result,
    ) throws -> Result {
        try validate()
        return try lease!.withSpan { span in
            var span = span
            return try body(&span)
        }
    }
}

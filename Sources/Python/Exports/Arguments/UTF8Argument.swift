//
//  Created by Anton Spivak
//

@safe
struct UTF8Argument: ~Copyable, ~Escapable, _PythonArgument {
    let owner: Object?
    let error: (any Swift.Error)?

    let start: UnsafePointer<UInt8>?
    let count: Int

    @_lifetime(copy owner)
    @unsafe
    init(
        owner: consuming Object?,
        start: UnsafePointer<UInt8>?,
        count: Int,
        error: (any Swift.Error)? = nil,
    ) {
        self.owner = consume owner
        unsafe self.start = start
        self.count = count
        self.error = error
    }

    mutating func validate() throws {
        if let error {
            throw error
        }
    }

    mutating func withValue<Result: ~Copyable>(
        _ body: (inout UTF8Span) throws -> Result,
    ) throws -> Result {
        try validate()
        let bytes = unsafe Span<UInt8>(_unsafeStart: start!, count: count)
        let span = unsafe UTF8Span(unchecked: bytes)
        var scoped = unsafe _overrideLifetime(span, borrowing: self)
        return try body(&scoped)
    }
}

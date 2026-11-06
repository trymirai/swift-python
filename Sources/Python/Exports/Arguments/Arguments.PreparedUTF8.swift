//
//  Created by Anton Spivak
//

// MARK: - Arguments.PreparedUTF8

extension Arguments {
    struct PreparedUTF8: ~Copyable, ~Escapable, _PArgument {
        private var view: PreparedValue<View>

        @_lifetime(copy view)
        init(_ view: consuming PreparedValue<View>) {
            self.view = view
        }

        borrowing func validate() throws {
            try view.validate()
        }

        mutating func withValue<Result: ~Copyable>(
            _ body: (inout UTF8Span) throws -> Result,
        ) throws -> Result {
            try view.withValue { try $0.withSpan(body) }
        }
    }
}

// MARK: - Arguments.PreparedUTF8.View

extension Arguments.PreparedUTF8 {
    @safe
    struct View: ~Copyable, ~Escapable {
        // The Python object owns the UTF-8 storage for the lifetime of this view.
        private let owner: Object
        private let bytes: UnsafeBufferPointer<UInt8>

        @_lifetime(copy owner)
        @unsafe
        init(owner: consuming Object, bytes: UnsafeBufferPointer<UInt8>) {
            self.owner = owner
            unsafe self.bytes = bytes
        }

        borrowing func withSpan<Result: ~Copyable>(
            _ body: (inout UTF8Span) throws -> Result,
        ) throws -> Result {
            let span = unsafe UTF8Span(unchecked: bytes.span)
            var scoped = unsafe _overrideLifetime(span, borrowing: self)
            return try body(&scoped)
        }
    }
}

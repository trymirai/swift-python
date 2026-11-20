//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    @_lifetime(borrow self)
    borrowing func utf8() throws -> UTF8Span {
        _ = try Interpreter.Storage.requireCurrent()

        guard let buffer = unsafe Self.utf8Buffer(pointer) else {
            throw Self.failure("Unable to read a Python string.")
        }
        let utf8 = unsafe UTF8Span(unchecked: buffer.span)
        return unsafe _overrideLifetime(utf8, borrowing: self)
    }

    /// Borrows a contiguous, native-format buffer. Calling back into Python during `body` throws.
    borrowing func withSpan<Element: BitwiseCopyable, Result: ~Copyable>(
        as type: Element.Type,
        _ body: (Span<Element>) throws -> Result,
    ) throws -> Result {
        let lease = unsafe try BufferLease<Element>(pointer, in: self)
        return try lease.withSpan(body)
    }

    /// Borrows a writable, native-format buffer. Its changes are visible through Python aliases.
    /// Calling back into Python or borrowing an overlapping byte range during `body` throws.
    borrowing func withMutableSpan<Element: BitwiseCopyable, Result: ~Copyable>(
        as type: Element.Type,
        _ body: (inout MutableSpan<Element>) throws -> Result,
    ) throws -> Result {
        let lease = unsafe try BufferLease<Element>.Mutable(pointer, in: self)
        return try lease.withMutableSpan(body)
    }
}

extension Object {
    // CPython owns the UTF-8 bytes for as long as the Unicode object is alive.
    @unsafe
    static func utf8Buffer(
        _ pointer: UnsafeMutablePointer<PyObject>,
    ) -> UnsafeBufferPointer<UInt8>? {
        var count = 0
        guard let bytes = unsafe PyUnicode_AsUTF8AndSize(pointer, &count) else {
            return nil
        }
        return unsafe UnsafeBufferPointer(
            start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
            count: count,
        )
    }
}

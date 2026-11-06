//
//  Created by Anton Spivak
//

internal import libcpython

extension Object {
    @_lifetime(borrow attachment)
    init(bytes: Span<UInt8>, in attachment: borrowing PThread.Attachment) throws {
        self = unsafe try Self.take(Self.copyBytes(bytes), in: attachment)
    }

    @unsafe
    static func copyBytes(_ bytes: Span<UInt8>) -> UnsafeMutablePointer<PyObject>? {
        // CPython copies the range synchronously; the Swift storage stays borrowed.
        bytes.withUnsafeBytes { buffer in
            unsafe PyBytes_FromStringAndSize(
                buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                buffer.count,
            )
        }
    }

    borrowing func value() throws -> Value {
        try value(depth: 0)
    }

    borrowing func value(depth: Int) throws -> Value {
        guard depth < 64 else {
            throw Exception(
                name: "ValueError",
                message: "Swift argument nesting exceeds 64 levels.",
            )
        }

        switch unsafe CPython_ValueTypeOf(pointer) {
        case CPython_ValueNone:
            return .none
        case CPython_ValueBool:
            return .bool(unsafe PyObject_IsTrue(pointer) == 1)
        case CPython_ValueInteger:
            let value = unsafe PyLong_AsLongLong(pointer)
            try Self.checkError("A Swift integer argument exceeds Int64.")
            return .integer(value)
        case CPython_ValueFloat:
            return .float(unsafe PyFloat_AsDouble(pointer))
        case CPython_ValueString:
            return .string(try string())
        case CPython_ValueBytes:
            return .bytes(try copiedBytes())
        case CPython_ValueSequence:
            return .list(try sequenceValues(depth: depth + 1))
        case CPython_ValueDictionary:
            let decoder = unsafe Decoder(pointer, depth: depth, in: self)
            return .dictionary(try decoder.dictionary(of: Value.self))
        default:
            throw Exception(
                name: "TypeError",
                message: "This Python value cannot be passed to Swift.",
            )
        }
    }

    private borrowing func copiedBytes() throws -> [UInt8] {
        let span = try bytes()
        return Array(capacity: span.count) { output in
            for index in span.indices {
                output.append(span[index])
            }
        }
    }

    private borrowing func sequenceValues(depth: Int) throws -> [Value] {
        let count = unsafe PySequence_Size(pointer)
        guard count >= 0 else {
            throw Self.failure("Unable to read a Python sequence.")
        }

        var values = [Value]()
        values.reserveCapacity(count)
        for index in 0 ..< count {
            let item = unsafe try Self.take(PySequence_GetItem(pointer, index), in: self)
            values.append(try item.value(depth: depth))
        }
        return values
    }

    @_lifetime(borrow self)
    public borrowing func utf8() throws -> UTF8Span {
        _ = try Interpreter.Storage.requireCurrent()

        guard let buffer = unsafe Self.utf8Buffer(pointer) else {
            throw Self.failure("Unable to read a Python string.")
        }
        let utf8 = unsafe UTF8Span(unchecked: buffer.span)
        return unsafe _overrideLifetime(utf8, borrowing: self)
    }

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

    @_lifetime(borrow self)
    private borrowing func bytes() throws -> Span<UInt8> {
        var bytes: UnsafeMutablePointer<CChar>?
        var count = 0
        guard
            unsafe PyBytes_AsStringAndSize(pointer, &bytes, &count) == 0,
            let bytes = unsafe bytes
        else {
            throw Self.failure("Unable to read a Python bytes value.")
        }
        let span = unsafe Span<UInt8>(
            _unsafeStart: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
            count: count,
        )
        // Exact bytes objects are immutable and retained by this Object.
        return unsafe _overrideLifetime(span, borrowing: self)
    }
}

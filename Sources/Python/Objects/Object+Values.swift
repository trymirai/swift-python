//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    @_lifetime(borrow owner)
    internal init<T: Encodable & ~Copyable, Owner: ~Copyable & ~Escapable>(
        encoding value: borrowing T,
        in owner: borrowing Owner,
    ) throws {
        var encoder = Encoder(in: owner)
        try value.encode(to: &encoder)
        self = unsafe try Object(owned: encoder.take(), in: owner)
    }

    /// Discards the result of a void-returning Swift binding.
    @_documentation(visibility: internal)
    borrowing func decode(as type: Void.Type) throws {
        _ = try Interpreter.Storage.requireCurrent()
    }

    borrowing func decode<T: Decodable & ~Copyable>(
        as type: T.Type = T.self,
    ) throws -> T {
        let decoder = unsafe Decoder(pointer, in: self)
        return try decoder.decode(type)
    }
}

extension Object {
    @_lifetime(borrow attachment)
    init(bytes: Span<UInt8>, in attachment: borrowing PThread.Attachment) throws {
        self = unsafe try Self.take(Self.copyBytes(bytes), in: attachment)
    }

    @unsafe
    static func copyBytes(_ bytes: Span<UInt8>) -> UnsafeMutablePointer<PyObject>? {
        // CPython copies the bytes before this borrow ends.
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
            throw Failure(
                .valueError,
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
            throw Failure(
                .typeError,
                message: "This Python value cannot be passed to Swift.",
            )
        }
    }

    private borrowing func copiedBytes() throws -> [UInt8] {
        let span = try bytes()
        return span.withUnsafeBufferPointer { unsafe Array($0) }
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

    borrowing func string() throws -> String {
        String(copying: try utf8())
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

//
//  Created by Anton Spivak
//

internal import libcpython

extension Object {
    @_lifetime(borrow attachment)
    init(bytes: Span<UInt8>, in attachment: borrowing ThreadState.Attachment) throws {
        // CPython copies the range synchronously; the Swift storage stays borrowed.
        let pointer = bytes.withUnsafeBytes { buffer in
            unsafe PyBytes_FromStringAndSize(
                buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                buffer.count,
            )
        }
        self = unsafe try Self.take(pointer, in: attachment)
    }

    borrowing func value() throws -> Value {
        try value(depth: 0)
    }

    private borrowing func value(depth: Int) throws -> Value {
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
            if unsafe PyErr_Occurred() != nil {
                throw Self.failure("A Swift integer argument exceeds Int64.")
            }
            return .integer(value)
        case CPython_ValueFloat:
            return .float(unsafe PyFloat_AsDouble(pointer))
        case CPython_ValueString:
            return .string(try string())
        case CPython_ValueBytes:
            let span = try bytes()
            return .bytes(Array(capacity: span.count) { output in
                for index in span.indices {
                    output.append(span[index])
                }
            })
        case CPython_ValueSequence:
            return .list(try sequenceValues(depth: depth + 1))
        case CPython_ValueDictionary:
            return .dictionary(try dictionaryValues(depth: depth + 1))
        default:
            throw Exception(
                name: "TypeError",
                message: "This Python value cannot be passed to Swift.",
            )
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

    private borrowing func dictionaryValues(depth: Int) throws -> [String: Value] {
        var position = 0
        var key: UnsafeMutablePointer<PyObject>?
        var value: UnsafeMutablePointer<PyObject>?
        var values = [String: Value]()
        while unsafe PyDict_Next(pointer, &position, &key, &value) != 0 {
            guard let key = unsafe key, let value = unsafe value else {
                throw Self.failure("Unable to read a Python dictionary.")
            }
            // Retain borrowed entries before conversion, including error formatting.
            unsafe Py_IncRef(key)
            let keyObject = unsafe Object(owned: key, in: self)
            unsafe Py_IncRef(value)
            let valueObject = unsafe Object(owned: value, in: self)
            values[try keyObject.string()] = try valueObject.value(depth: depth)
        }
        return values
    }

    @_lifetime(borrow self)
    public borrowing func utf8() throws -> UTF8Span {
        _ = try InterpreterStorage.requireCurrent()
        var count = 0
        guard let bytes = unsafe PyUnicode_AsUTF8AndSize(pointer, &count) else {
            throw Self.failure("Unable to read a Python string.")
        }
        let span = unsafe Span<UInt8>(
            _unsafeStart: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
            count: count,
        )
        // CPython owns this valid UTF-8 buffer until this reference is released.
        let utf8 = unsafe UTF8Span(unchecked: span)
        return unsafe _overrideLifetime(utf8, borrowing: self)
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

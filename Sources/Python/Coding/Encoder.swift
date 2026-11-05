//
//  Created by Anton Spivak
//

internal import libcpython

/// A single-value encoder. Its Python reference is released before its owner detaches.
@safe
public struct Encoder: ~Copyable, ~Escapable {
    private var output: UnsafeMutablePointer<PyObject>?

    @_lifetime(borrow owner)
    init<Owner: ~Copyable & ~Escapable>(in owner: borrowing Owner) {
        unsafe self.output = nil
    }

    deinit {
        if let output = unsafe output {
            unsafe InterpreterStorage.release(output)
        }
    }

    public mutating func encode<T: Encodable & ~Copyable>(_ value: borrowing T) throws {
        _ = try InterpreterStorage.requireCurrent()
        try value.encode(to: &self)
    }

    public mutating func encodeNil() throws {
        _ = try InterpreterStorage.requireCurrent()
        unsafe try replace(Py_GetConstant(UInt32(Py_CONSTANT_NONE)))
    }

    public mutating func encode(_ value: ()) throws {
        try encodeNil()
    }

    public mutating func encode(_ value: consuming Object) throws {
        _ = try InterpreterStorage.requireCurrent()
        unsafe try replace(value.release())
    }

    public mutating func encode(_ value: Bool) throws {
        _ = try InterpreterStorage.requireCurrent()
        unsafe try replace(PyBool_FromLong(value ? 1 : 0))
    }

    public mutating func encode(_ value: Double) throws {
        _ = try InterpreterStorage.requireCurrent()
        unsafe try replace(PyFloat_FromDouble(value))
    }

    public mutating func encode(_ value: borrowing String) throws {
        _ = try InterpreterStorage.requireCurrent()
        let pointer = value.withCString { unsafe PyUnicode_FromStringAndSize($0, value.utf8.count) }
        unsafe try replace(pointer)
    }

    public mutating func encodeInteger<T: FixedWidthInteger>(_ value: T) throws {
        _ = try InterpreterStorage.requireCurrent()
        if let signed = Int64(exactly: value) {
            unsafe try replace(PyLong_FromLongLong(signed))
        } else if let unsigned = UInt64(exactly: value) {
            unsafe try replace(PyLong_FromUnsignedLongLong(unsigned))
        } else {
            let pointer = String(value).withCString { unsafe PyLong_FromString($0, nil, 10) }
            unsafe try replace(pointer)
        }
    }

    public mutating func encodeBytes(_ value: Span<UInt8>) throws {
        _ = try InterpreterStorage.requireCurrent()
        let pointer = value.withUnsafeBytes {
            unsafe PyBytes_FromStringAndSize(
                $0.baseAddress?.assumingMemoryBound(to: CChar.self),
                $0.count,
            )
        }
        unsafe try replace(pointer)
    }

    public mutating func encode<Element: Encodable>(_ values: borrowing [Element]) throws {
        _ = try InterpreterStorage.requireCurrent()
        let result = unsafe try Object.take(PyList_New(values.count), in: self)
        for index in values.indices {
            let value = try Object(encoding: values[index], in: self)
            guard unsafe PyList_SetItem(result.pointer, index, value.release()) == 0 else {
                throw Object.failure("Unable to encode a Python list.")
            }
        }
        unsafe try replace(result.release())
    }

    public mutating func encode<Element: Encodable>(_ values: borrowing [String: Element]) throws {
        _ = try InterpreterStorage.requireCurrent()
        let result = unsafe try Object.take(PyDict_New(), in: self)
        for (key, value) in copy values {
            let key = try Object(encoding: key, in: self)
            let value = try Object(encoding: value, in: self)
            guard unsafe PyDict_SetItem(result.pointer, key.pointer, value.pointer) == 0 else {
                throw Object.failure("Unable to encode a Python dictionary.")
            }
        }
        unsafe try replace(result.release())
    }

    /// Adds a field to a dictionary produced by this encoder.
    public mutating func encode<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forKey key: String,
    ) throws {
        _ = try InterpreterStorage.requireCurrent()
        if unsafe output == nil {
            unsafe try replace(PyDict_New())
        }
        guard
            let output = unsafe output,
            unsafe CPython_ValueTypeOf(output) == CPython_ValueDictionary
        else {
            throw Exception(
                name: "TypeError",
                message: "The encoder already contains a non-dictionary value.",
            )
        }
        let key = try Object(encoding: key, in: self)
        let value = try Object(encoding: value, in: self)
        guard unsafe PyDict_SetItem(output, key.pointer, value.pointer) == 0 else {
            throw Object.failure("Unable to encode a Python field.")
        }
    }

    /// Encodes a positional record, appending fields in order.
    public mutating func encode<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        at index: Int,
    ) throws {
        _ = try InterpreterStorage.requireCurrent()
        if unsafe output == nil {
            unsafe try replace(PyList_New(0))
        }
        guard
            let output = unsafe output,
            unsafe CPython_ValueTypeOf(output) == CPython_ValueSequence
        else {
            throw Exception(
                name: "TypeError",
                message: "The encoder already contains a non-list value.",
            )
        }
        let count = unsafe PyList_Size(output)
        guard index >= 0, index <= count else {
            throw Exception(name: "IndexError", message: "Encode positional fields in order.")
        }
        let object = try Object(encoding: value, in: self)
        let status = if index == count {
            unsafe PyList_Append(output, object.pointer)
        } else {
            unsafe PyList_SetItem(output, index, object.release())
        }
        guard status == 0 else {
            throw Object.failure("Unable to encode a positional field.")
        }
    }

    @unsafe
    mutating func replace(_ pointer: UnsafeMutablePointer<PyObject>?) throws {
        guard let pointer = unsafe pointer
        else {
            throw Object.failure("Unable to encode a Python value.")
        }
        let previous = unsafe output
        unsafe output = pointer
        if let previous = unsafe previous {
            unsafe InterpreterStorage.release(previous)
        }
    }

    @unsafe
    mutating func take() throws -> UnsafeMutablePointer<PyObject> {
        guard let pointer = unsafe output else {
            throw Exception(
                name: "ValueError",
                message: "The encoder did not produce a value.",
            )
        }
        unsafe output = nil
        return unsafe pointer
    }
}

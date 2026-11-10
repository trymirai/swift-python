//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Encoder

/// A single-value encoder. Its Python reference is released before its owner detaches.
@safe
public struct Encoder: ~Copyable, ~Escapable {
    private var output: Output?

    @_lifetime(borrow owner)
    init<Owner: ~Copyable & ~Escapable>(in owner: borrowing Owner) {
        unsafe self.output = nil
    }

    deinit {
        if let output = unsafe output {
            unsafe Interpreter.Storage.release(output.pointer)
        }
    }

    public mutating func encode<T: Encodable & ~Copyable>(_ value: borrowing T) throws {
        _ = try Interpreter.Storage.requireCurrent()
        try value.encode(to: &self)
    }

    // MARK: Scalar values

    public mutating func encodeNil() throws {
        _ = try Interpreter.Storage.requireCurrent()
        unsafe try replace(Py_GetConstant(UInt32(Py_CONSTANT_NONE)))
    }

    public mutating func encode(_ value: ()) throws {
        try encodeNil()
    }

    public mutating func encode(_ value: consuming Object) throws {
        _ = try Interpreter.Storage.requireCurrent()
        let pointer = unsafe value.release()

        let output: Output = if unsafe CPython_ValueTypeOf(pointer) == CPython_ValueDictionary {
            unsafe .dictionary(pointer)
        } else if unsafe CPython_IsList(pointer) {
            unsafe .list(pointer)
        } else {
            unsafe .value(pointer)
        }
        unsafe assign(output)
    }

    public mutating func encode(_ value: Bool) throws {
        _ = try Interpreter.Storage.requireCurrent()
        unsafe try replace(PyBool_FromLong(value ? 1 : 0))
    }

    public mutating func encode(_ value: Double) throws {
        _ = try Interpreter.Storage.requireCurrent()
        unsafe try replace(PyFloat_FromDouble(value))
    }

    public mutating func encode(_ value: borrowing String) throws {
        _ = try Interpreter.Storage.requireCurrent()
        let pointer = value.withCString { unsafe PyUnicode_FromStringAndSize($0, value.utf8.count) }
        unsafe try replace(pointer)
    }

    public mutating func encodeInteger<T: FixedWidthInteger>(_ value: T) throws {
        _ = try Interpreter.Storage.requireCurrent()

        let pointer = if let signed = Int64(exactly: value) {
            unsafe PyLong_FromLongLong(signed)
        } else if let unsigned = UInt64(exactly: value) {
            unsafe PyLong_FromUnsignedLongLong(unsigned)
        } else {
            String(value).withCString { unsafe PyLong_FromString($0, nil, 10) }
        }
        unsafe try replace(pointer)
    }

    public mutating func encodeBytes(_ value: Span<UInt8>) throws {
        _ = try Interpreter.Storage.requireCurrent()
        unsafe try replace(Object.copyBytes(value))
    }

    // MARK: Containers and fields

    public mutating func encode<Element: Encodable>(_ values: borrowing [Element]) throws {
        _ = try Interpreter.Storage.requireCurrent()
        let result = unsafe try Object.take(PyList_New(values.count), in: self)

        for index in values.indices {
            let value = try Object(encoding: values[index], in: self)
            unsafe try Self.setListItem(value, at: index, in: result.pointer)
        }

        unsafe assign(.list(result.release()))
    }

    public mutating func encode<Element: Encodable>(_ values: borrowing [String: Element]) throws {
        _ = try Interpreter.Storage.requireCurrent()
        let result = unsafe try Object.take(PyDict_New(), in: self)

        for (key, value) in copy values {
            unsafe try setDictionaryItem(
                value,
                forKey: key,
                in: result.pointer,
                errorMessage: "Unable to encode a Python dictionary.",
            )
        }

        unsafe assign(.dictionary(result.release()))
    }

    /// Creates a dictionary on the first field. Throws `TypeError` for a non-dictionary value.
    public mutating func encode<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forKey key: String,
    ) throws {
        _ = try Interpreter.Storage.requireCurrent()
        let dictionary = unsafe try dictionaryOutput()

        unsafe try setDictionaryItem(
            value,
            forKey: key,
            in: dictionary,
            errorMessage: "Unable to encode a Python field.",
        )
    }

    /// Appends at the current count or replaces an existing positional field.
    public mutating func encode<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        at index: Int,
    ) throws {
        _ = try Interpreter.Storage.requireCurrent()
        let list = unsafe try listOutput()

        let count = unsafe PyList_Size(list)
        guard count >= 0 else {
            throw Object.failure("Unable to read the Python list size.")
        }
        guard index >= 0, index <= count else {
            throw Exception(name: "IndexError", message: "Encode positional fields in order.")
        }

        let object = try Object(encoding: value, in: self)
        if index == count {
            try Object.check(
                unsafe PyList_Append(list, object.pointer),
                "Unable to append a positional field.",
            )
        } else {
            unsafe try Self.setListItem(object, at: index, in: list)
        }
    }

    @unsafe
    private mutating func dictionaryOutput() throws -> UnsafeMutablePointer<PyObject> {
        switch unsafe output {
        case let .dictionary(dictionary):
            return unsafe dictionary
        case nil:
            let dictionary = unsafe try Object.require(
                PyDict_New(),
                "Unable to create a Python dictionary.",
            )
            unsafe assign(.dictionary(dictionary))
            return unsafe dictionary
        default:
            throw Exception(
                name: "TypeError",
                message: "The encoder already contains a non-dictionary value.",
            )
        }
    }

    @unsafe
    private mutating func listOutput() throws -> UnsafeMutablePointer<PyObject> {
        switch unsafe output {
        case let .list(list):
            return unsafe list
        case nil:
            let list = unsafe try Object.require(PyList_New(0), "Unable to create a Python list.")
            unsafe assign(.list(list))
            return unsafe list
        default:
            throw Exception(
                name: "TypeError",
                message: "The encoder already contains a non-list value.",
            )
        }
    }

    @unsafe
    private borrowing func setDictionaryItem<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forKey key: String,
        in dictionary: UnsafeMutablePointer<PyObject>,
        errorMessage: String,
    ) throws {
        let key = try Object(encoding: key, in: self)
        let value = try Object(encoding: value, in: self)
        try Object.check(
            unsafe PyDict_SetItem(dictionary, key.pointer, value.pointer),
            errorMessage,
        )
    }

    @unsafe
    private static func setListItem(
        _ value: consuming Object,
        at index: Int,
        in list: UnsafeMutablePointer<PyObject>,
    ) throws {
        try Object.check(
            unsafe PyList_SetItem(list, index, value.release()),
            "Unable to set a Python list item.",
        )
    }

    // MARK: Output ownership

    @unsafe
    mutating func replace(_ pointer: UnsafeMutablePointer<PyObject>?) throws {
        let pointer = unsafe try Object.require(pointer, "Unable to encode a Python value.")
        unsafe assign(.value(pointer))
    }

    @unsafe
    private mutating func assign(_ value: Output) {
        let previous = unsafe output
        unsafe output = value

        // Releasing the previous value can run Python finalizers.
        if let previous = unsafe previous {
            unsafe Interpreter.Storage.release(previous.pointer)
        }
    }

    @unsafe
    mutating func take() throws -> UnsafeMutablePointer<PyObject> {
        guard let value = unsafe output else {
            throw Exception(
                name: "ValueError",
                message: "The encoder did not produce a value.",
            )
        }
        unsafe output = nil
        return unsafe value.pointer
    }
}

// MARK: Encoder.Output

private extension Encoder {
    @unsafe
    enum Output {
        case value(UnsafeMutablePointer<PyObject>)
        case list(UnsafeMutablePointer<PyObject>)
        case dictionary(UnsafeMutablePointer<PyObject>)

        var pointer: UnsafeMutablePointer<PyObject> {
            switch unsafe self {
            case let .value(pointer), let .list(pointer), let .dictionary(pointer):
                unsafe pointer
            }
        }
    }
}

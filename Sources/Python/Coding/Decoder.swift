//
//  Created by Anton Spivak
//

internal import libcpython

/// Reads a Python value without materializing an intermediate value tree.
@safe
public struct Decoder: ~Copyable, ~Escapable {
    let pointer: UnsafeMutablePointer<PyObject>
    let depth: Int

    @_lifetime(borrow owner)
    @unsafe
    init<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>,
        depth: Int = 0,
        in owner: borrowing Owner,
    ) {
        unsafe self.pointer = pointer
        self.depth = depth
    }

    @_lifetime(borrow self)
    public borrowing func object() throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        return unsafe Object.retaining(pointer, in: self)
    }

    public borrowing func decode<T: Decodable & ~Copyable>(_ type: T.Type = T.self) throws -> T {
        _ = try Interpreter.Storage.requireCurrent()
        guard depth < 64 else {
            throw Exception(
                name: "ValueError",
                message: "Python value nesting exceeds 64 levels.",
            )
        }
        return try T(from: self)
    }

    public var isNone: Bool {
        unsafe CPython_ValueTypeOf(pointer) == CPython_ValueNone
    }

    public borrowing func bool() throws -> Bool {
        try requireValueType(CPython_ValueBool, expected: "bool")
        return unsafe PyObject_IsTrue(pointer) != 0
    }

    public borrowing func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        try requireValueType(CPython_ValueInteger, expected: "int")

        if T.bitWidth > 64 {
            let text = unsafe try Object.take(PyObject_Str(pointer), in: self)
            guard let value = T(try text.string(), radix: 10) else {
                throw overflow(type)
            }
            return value
        }

        func exactInteger(_ value: some BinaryInteger) throws -> T {
            try Object.checkError("Python integer is out of range.")
            guard let result = T(exactly: value) else {
                throw overflow(type)
            }
            return result
        }

        if T.isSigned {
            return unsafe try exactInteger(PyLong_AsLongLong(pointer))
        }
        return unsafe try exactInteger(PyLong_AsUnsignedLongLong(pointer))
    }

    public borrowing func double() throws -> Double {
        let kind = try checkedValueType()
        guard kind == CPython_ValueFloat || kind == CPython_ValueInteger else {
            throw mismatch("float")
        }

        let value = unsafe PyFloat_AsDouble(pointer)
        try Object.checkError("Unable to decode a Python float.")
        return value
    }

    public borrowing func string() throws -> String {
        try requireValueType(CPython_ValueString, expected: "str")
        let value = unsafe Object.retaining(pointer, in: self)
        return try value.string()
    }

    public var count: Int {
        get throws {
            let kind = try checkedValueType()
            guard kind == CPython_ValueSequence || kind == CPython_ValueDictionary else {
                throw mismatch("list, tuple or dict")
            }

            let result = unsafe PyObject_Length(pointer)
            guard result >= 0 else {
                throw Object.failure("Unable to read a Python container.")
            }
            return result
        }
    }

    public borrowing func decode<T: Decodable & ~Copyable>(
        _ type: T.Type,
        forKey key: String,
    ) throws -> T {
        try item(.string(key)).get(as: type)
    }

    public borrowing func decode<T: Decodable & ~Copyable>(
        _ type: T.Type,
        at index: Int,
    ) throws -> T {
        try item(.index(index)).get(as: type)
    }

    public borrowing func keys() throws -> [String] {
        try requireValueType(CPython_ValueDictionary, expected: "dict")
        let keys = unsafe try Object.take(PyDict_Keys(pointer), in: self)
        return try keys.decode(as: [String].self)
    }

    borrowing func dictionary<Element: Decodable>(
        of type: Element.Type,
    ) throws -> [String: Element] {
        let keys = try keys()
        var result = [String: Element](minimumCapacity: keys.count)

        // Swift's canonical Unicode equality can merge distinct Python strings.
        for key in keys {
            guard result.index(forKey: key) == nil else {
                throw Exception(
                    name: "ValueError",
                    message: "Python dictionary keys collide in Swift: \(key.debugDescription).",
                )
            }
            result[key] = try decode(type, forKey: key)
        }
        return result
    }

    @_lifetime(borrow self)
    private borrowing func item(_ key: Object.Item.Key) -> Object.Item {
        unsafe Object.Item(container: pointer, key: key, depth: depth + 1, in: self)
    }

    private borrowing func checkedValueType() throws -> CPython_ValueType {
        _ = try Interpreter.Storage.requireCurrent()
        return unsafe CPython_ValueTypeOf(pointer)
    }

    private borrowing func requireValueType(_ type: CPython_ValueType, expected: String) throws {
        guard try checkedValueType() == type else {
            throw mismatch(expected)
        }
    }

    func mismatch(_ expected: String) -> Exception {
        Exception(name: "TypeError", message: "Expected Python \(expected).")
    }

    private func overflow<T>(_ type: T.Type) -> Exception {
        Exception(name: "OverflowError", message: "Python integer does not fit \(type).")
    }
}

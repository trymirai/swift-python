//
//  Created by Anton Spivak
//

internal import libcpython

/// Reads a Python value without materializing an intermediate value tree.
@safe
public struct Decoder: ~Copyable, ~Escapable {
    let pointer: UnsafeMutablePointer<PyObject>
    let depth: Int

    public var count: Int {
        get throws {
            _ = try InterpreterStorage.requireCurrent()
            let kind = unsafe CPython_ValueTypeOf(pointer)
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

    public subscript(_ key: String) -> Item {
        @_lifetime(borrow self)
        get { unsafe Item(container: pointer, key: .string(key), depth: depth + 1, in: self) }
    }

    public subscript(_ index: Int) -> Item {
        @_lifetime(borrow self)
        get { unsafe Item(container: pointer, key: .index(index), depth: depth + 1, in: self) }
    }

    public borrowing func get<T: Decodable & ~Copyable>(as type: T.Type = T.self) throws -> T {
        _ = try InterpreterStorage.requireCurrent()
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
        _ = try InterpreterStorage.requireCurrent()
        guard unsafe CPython_ValueTypeOf(pointer) == CPython_ValueBool
        else {
            throw mismatch("bool")
        }
        return unsafe PyObject_IsTrue(pointer) != 0
    }

    public borrowing func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        _ = try InterpreterStorage.requireCurrent()
        guard unsafe CPython_ValueTypeOf(pointer) == CPython_ValueInteger
        else {
            throw mismatch("int")
        }
        if T.bitWidth > 64 {
            let text = unsafe try Object.take(PyObject_Str(pointer), in: self)
            guard let value = T(try text.string(), radix: 10) else {
                throw overflow(type)
            }
            return value
        }
        if T.isSigned {
            let value = unsafe PyLong_AsLongLong(pointer)
            guard unsafe PyErr_Occurred() == nil
            else {
                throw Object.failure("Python integer is out of range.")
            }
            guard let result = T(exactly: value) else {
                throw overflow(type)
            }
            return result
        }
        let value = unsafe PyLong_AsUnsignedLongLong(pointer)
        guard unsafe PyErr_Occurred() == nil
        else {
            throw Object.failure("Python integer is out of range.")
        }
        guard let result = T(exactly: value) else {
            throw overflow(type)
        }
        return result
    }

    public borrowing func double() throws -> Double {
        _ = try InterpreterStorage.requireCurrent()
        let kind = unsafe CPython_ValueTypeOf(pointer)
        guard kind == CPython_ValueFloat || kind == CPython_ValueInteger
        else {
            throw mismatch("float")
        }
        let value = unsafe PyFloat_AsDouble(pointer)
        guard unsafe PyErr_Occurred() == nil
        else {
            throw Object.failure("Unable to decode a Python float.")
        }
        return value
    }

    public borrowing func string() throws -> String {
        _ = try InterpreterStorage.requireCurrent()
        guard unsafe CPython_ValueTypeOf(pointer) == CPython_ValueString
        else {
            throw mismatch("str")
        }
        unsafe Py_IncRef(pointer)
        let value = unsafe Object(owned: pointer, in: self)
        return try value.string()
    }

    public borrowing func keys() throws -> [String] {
        _ = try InterpreterStorage.requireCurrent()
        guard unsafe CPython_ValueTypeOf(pointer) == CPython_ValueDictionary
        else {
            throw mismatch("dict")
        }
        let keys = unsafe try Object.take(PyDict_Keys(pointer), in: self)
        return try keys.decode(as: [String].self)
    }

    func mismatch(_ expected: String) -> Exception {
        Exception(name: "TypeError", message: "Expected Python \(expected).")
    }

    private func overflow<T>(_ type: T.Type) -> Exception {
        Exception(name: "OverflowError", message: "Python integer does not fit \(type).")
    }
}

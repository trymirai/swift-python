//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    @_lifetime(copy self)
    borrowing func value(forAttribute name: String) throws -> Object {
        let name = try attributeName(name)
        return unsafe try Self.take(PyObject_GetAttr(pointer, name.pointer), inheriting: self)
    }

    /// Returns `nil` for a missing attribute. A present Python `None` has its own `Object`.
    @_lifetime(copy self)
    borrowing func valueIfPresent(forAttribute name: String) throws -> Object? {
        let key = try attributeName(name)
        var result: UnsafeMutablePointer<PyObject>?
        let status = unsafe PyObject_GetOptionalAttr(pointer, key.pointer, &result)

        guard status >= 0 else {
            throw Self.failure("Unable to look up a Python attribute.")
        }
        guard let result = unsafe result else {
            return nil
        }

        return unsafe try Self.take(result, inheriting: self)
    }

    borrowing func set<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forAttribute name: String,
    ) throws {
        let name = try attributeName(name)
        let value = try Object(encoding: value, in: self)
        try Self.check(
            unsafe PyObject_SetAttr(pointer, name.pointer, value.pointer),
            "Unable to set a Python attribute.",
        )
    }

    @_lifetime(borrow self)
    private borrowing func attributeName(_ name: String) throws -> Object {
        // Attribute names can contain NUL and must reach CPython as Unicode objects.
        _ = try Interpreter.Storage.requireCurrent()
        return try Object(encoding: name, in: self)
    }
}

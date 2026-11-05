//
//  Created by Anton Spivak
//

internal import libcpython

/// A scoped name in the session's working namespace. Each operation resolves it afresh.
@safe
public struct Item: ~Copyable, ~Escapable {
    enum Key {
        case name(String)
        case string(String)
        case index(Int)
    }

    private let container: UnsafeMutablePointer<PyObject>
    private let key: Key
    private let depth: Int

    @_lifetime(borrow owner)
    @unsafe
    init<Owner: ~Copyable & ~Escapable>(
        container: UnsafeMutablePointer<PyObject>,
        key: Key,
        depth: Int = 0,
        in owner: borrowing Owner,
    ) {
        unsafe self.container = container
        self.key = key
        self.depth = depth
    }

    public borrowing func get<T: Decodable & ~Copyable>(as type: T.Type = T.self) throws -> T {
        let value = try object()
        let decoder = unsafe Decoder(value.pointer, depth: depth, in: value)
        return try decoder.get(as: type)
    }

    @_lifetime(copy self)
    public borrowing func object() throws -> Object {
        _ = try InterpreterStorage.requireCurrent()
        let key = try keyObject()
        guard let value = unsafe PyObject_GetItem(container, key.pointer) else {
            throw missing()
        }
        return unsafe try Object.take(value, inheriting: self)
    }

    public borrowing func set<T: Encodable & ~Copyable>(_ value: borrowing T) throws {
        _ = try InterpreterStorage.requireCurrent()
        let key = try keyObject()
        let value = try Object(encoding: value, in: self)
        guard unsafe PyObject_SetItem(container, key.pointer, value.pointer) == 0 else {
            throw Object.failure("Unable to set a Python variable.")
        }
    }

    public borrowing func remove() throws {
        _ = try InterpreterStorage.requireCurrent()
        let key = try keyObject()
        guard unsafe PyObject_DelItem(container, key.pointer) == 0 else {
            throw missing()
        }
    }

    @_lifetime(borrow self)
    private borrowing func keyObject() throws -> Object {
        switch key {
        case let .name(value), let .string(value):
            try Object(encoding: value, in: self)
        case let .index(value):
            try Object(encoding: value, in: self)
        }
    }

    private borrowing func missing() -> any Swift.Error {
        if case let .name(name) = key, CPython_IsKeyError() != 0 {
            PyErr_Clear()
            return Exception(name: "NameError", message: "Python name '\(name)' is not defined.")
        }
        return Object.failure("Unable to access a Python variable.")
    }
}

//
//  Created by Anton Spivak
//

internal import libcpython

extension Object {
    /// A scoped lookup into a Python container. Namespace names report NameError.
    @safe
    struct Item: ~Copyable, ~Escapable {
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

        borrowing func get<T: Decodable & ~Copyable>(as type: T.Type = T.self) throws -> T {
            let value = unsafe try Object(owned: newReference(), in: self)
            let decoder = unsafe Decoder(value.pointer, depth: depth, in: value)
            return try decoder.decode(type)
        }

        /// The caller owns the reference returned by PyObject_GetItem.
        @unsafe
        borrowing func newReference() throws -> UnsafeMutablePointer<PyObject> {
            let key = try checkedKey()
            guard let value = unsafe PyObject_GetItem(container, key.pointer) else {
                throw missing()
            }
            return unsafe value
        }

        borrowing func set<T: Encodable & ~Copyable>(_ value: borrowing T) throws {
            _ = try Interpreter.Storage.requireCurrent()
            let value = try Object(encoding: value, in: self)
            try set(value)
        }

        borrowing func set(_ value: borrowing Object) throws {
            let key = try checkedKey()
            try Object.check(
                unsafe PyObject_SetItem(container, key.pointer, value.pointer),
                "Unable to set a Python variable.",
            )
        }

        borrowing func remove() throws {
            let key = try checkedKey()
            guard unsafe PyObject_DelItem(container, key.pointer) == 0 else {
                throw missing()
            }
        }

        @_lifetime(borrow self)
        private borrowing func checkedKey() throws -> Object {
            _ = try Interpreter.Storage.requireCurrent()
            return switch key {
            case let .name(value), let .string(value):
                try Object(encoding: value, in: self)
            case let .index(value):
                try Object(encoding: value, in: self)
            }
        }

        private borrowing func missing() -> any Swift::Error {
            if case let .name(name) = key, CPython_IsKeyError() != 0 {
                PyErr_Clear()
                return Failure(
                    .nameError,
                    message: "Python name '\(name)' is not defined.",
                )
            }
            return Object.failure("Unable to access a Python variable.")
        }
    }
}

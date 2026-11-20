//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    @_lifetime(copy self)
    borrowing func value(forKey key: String) throws -> Object {
        try value(for: .string(key))
    }

    @_lifetime(copy self)
    borrowing func value(at index: Int) throws -> Object {
        try value(for: .index(index))
    }

    borrowing func set<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forKey key: String,
    ) throws {
        try item(.string(key)).set(value)
    }

    borrowing func set<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        at index: Int,
    ) throws {
        try item(.index(index)).set(value)
    }

    borrowing func remove(_ key: String) throws {
        try item(.string(key)).remove()
    }

    borrowing func remove(_ index: Int) throws {
        try item(.index(index)).remove()
    }

    /// Iterates lazily with a local reference to the current element.
    borrowing func forEach(_ body: (borrowing Object) throws -> Void) throws {
        _ = try Interpreter.Storage.requireCurrent()
        let iterator = unsafe try Self.take(PyObject_GetIter(pointer), in: self)
        while let next = unsafe PyIter_Next(iterator.pointer) {
            let item = unsafe Object(owned: next, in: iterator)
            try body(item)
        }
        try Self.checkError("Unable to advance the Python iterator.")
    }
}

extension Object {
    @_lifetime(copy self)
    borrowing func value(for key: Object.Item.Key) throws -> Object {
        let reference = unsafe try item(key).newReference()
        return unsafe try Self.take(reference, inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func tupleItem(at index: Int) throws -> Object {
        let item = unsafe try Self.tupleItem(
            pointer,
            at: index,
            failure: "Unable to read the Python tuple.",
        )
        return unsafe Self.retaining(item, inheriting: self)
    }

    // A tuple owns its entries. The caller retains an entry to use it independently.
    @unsafe
    static func tupleItem(
        _ tuple: UnsafeMutablePointer<PyObject>,
        at index: Int,
        failure message: String,
    ) throws -> UnsafeMutablePointer<PyObject> {
        unsafe try require(PyTuple_GetItem(tuple, index), message)
    }

    @unsafe
    static func setListItem(
        _ value: consuming Object,
        at index: Int,
        in list: UnsafeMutablePointer<PyObject>,
        failure message: String = "Unable to set a Python list item.",
    ) throws {
        // PyList_SetItem takes ownership on both success and failure.
        try check(unsafe PyList_SetItem(list, index, value.release()), message)
    }

    @_lifetime(borrow self)
    borrowing func item(_ key: Object.Item.Key) -> Object.Item {
        unsafe Object.Item(container: pointer, key: key, in: self)
    }
}

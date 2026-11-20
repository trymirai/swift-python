//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Object

/// An owned Python reference scoped to its interpreter attachment.
@safe
public struct Object: ~Copyable, ~Escapable {
    let pointer: UnsafeMutablePointer<PyObject>

    @_lifetime(borrow owner)
    @unsafe
    init<Owner: ~Copyable & ~Escapable>(
        owned pointer: UnsafeMutablePointer<PyObject>,
        in owner: borrowing Owner,
    ) {
        unsafe self.pointer = pointer
    }

    deinit {
        unsafe Interpreter.Storage.release(pointer)
    }
}

public extension Object {
    borrowing func retain(in context: borrowing Context) throws -> Reference {
        try context.checkAccess()
        return unsafe try context.references.retain(pointer)
    }
}

extension Object {
    @_lifetime(borrow owner)
    @unsafe
    static func take<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>?,
        in owner: borrowing Owner,
    ) throws -> Object {
        unsafe try Object(owned: require(pointer, "A Python operation failed."), in: owner)
    }

    @_lifetime(borrow owner)
    @unsafe
    static func retaining<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>,
        in owner: borrowing Owner,
    ) -> Object {
        unsafe Py_IncRef(pointer)
        return unsafe Object(owned: pointer, in: owner)
    }

    // Owned results can share the source's interpreter lifetime.
    @_lifetime(copy owner)
    @unsafe
    static func take<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>?,
        inheriting owner: borrowing Owner,
    ) throws -> Object {
        let value = unsafe try take(pointer, in: owner)
        return unsafe _overrideLifetime(consume value, copying: owner)
    }

    @_lifetime(copy owner)
    @unsafe
    static func retaining<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>,
        inheriting owner: borrowing Owner,
    ) -> Object {
        let value = unsafe retaining(pointer, in: owner)
        return unsafe _overrideLifetime(consume value, copying: owner)
    }

    @unsafe
    consuming func release() -> UnsafeMutablePointer<PyObject> {
        let pointer = unsafe pointer
        discard self
        return unsafe pointer
    }

    @_lifetime(copy self)
    borrowing func retained() -> Object {
        unsafe Self.retaining(pointer, inheriting: self)
    }

    // The owning interpreter must be attached while the pending references are released.
    @unsafe
    static func decrementReferences(_ pointers: [UInt]) {
        for bits in pointers {
            if let pointer = unsafe UnsafeMutablePointer<PyObject>(bitPattern: bits) {
                unsafe Py_DecRef(pointer)
            }
        }
    }
}

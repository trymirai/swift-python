//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Object

// Owns one Python reference. Borrowing the attachment prevents its final DECREF
// from moving past the point where the interpreter releases its thread state.
@safe
public struct Object: ~Copyable, ~Escapable {
    let pointer: UnsafeMutablePointer<PyObject>

    @_lifetime(borrow owner)
    init<Owner: ~Copyable & ~Escapable>(
        owned pointer: UnsafeMutablePointer<PyObject>,
        in owner: borrowing Owner,
    ) {
        unsafe self.pointer = pointer
    }

    deinit {
        unsafe InterpreterStorage.release(pointer)
    }

    static func installImporter(in attachment: borrowing ThreadState.Attachment) throws {
        guard CPython_InstallEmbeddedImporter() == 0 else {
            throw failure("Unable to install the embedded importer.")
        }
    }

    @_lifetime(borrow owner)
    static func `import`<Owner: ~Copyable & ~Escapable>(
        module name: String,
        in owner: borrowing Owner,
    ) throws -> Object {
        guard !name.utf8.contains(0) else {
            throw Exception(
                name: "ValueError",
                message: "A Python module name cannot contain NUL.",
            )
        }
        return unsafe try take(PyImport_ImportModule(name), in: owner)
    }

    @_lifetime(copy self)
    public borrowing func attribute(_ name: String) throws -> Object {
        _ = try InterpreterStorage.requireCurrent()
        let name = try Object(encoding: name, in: self)
        return unsafe try Self.take(PyObject_GetAttr(pointer, name.pointer), inheriting: self)
    }

    public borrowing func setAttribute<T: Encodable & ~Copyable>(
        _ name: String,
        to value: borrowing T,
    ) throws {
        _ = try InterpreterStorage.requireCurrent()
        let name = try Object(encoding: name, in: self)
        let value = try Object(encoding: value, in: self)
        guard unsafe PyObject_SetAttr(pointer, name.pointer, value.pointer) == 0 else {
            throw Self.failure("Unable to set a Python attribute.")
        }
    }

    borrowing func string() throws -> String {
        String(copying: try utf8())
    }

    @_lifetime(borrow owner)
    static func take<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>?,
        in owner: borrowing Owner,
    ) throws -> Object {
        guard let pointer = unsafe pointer else {
            throw failure("A Python operation failed.")
        }
        return unsafe Object(owned: pointer, in: owner)
    }

    // Owning results inherit the source's interpreter lifetime, rather than the
    // temporary source object itself. Borrowed spans continue to borrow self.
    @_lifetime(copy owner)
    @unsafe
    static func take<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>?,
        inheriting owner: borrowing Owner,
    ) throws -> Object {
        let value = unsafe try take(pointer, in: owner)
        return unsafe _overrideLifetime(consume value, copying: owner)
    }

    consuming func release() -> UnsafeMutablePointer<PyObject> {
        let pointer = unsafe pointer
        discard self
        return unsafe pointer
    }
}

// MARK: Object.Callable

extension Object {
    // A method requirement preserves the result's lifetime dependency through
    // existential dispatch. Stored function values cannot express it in Swift 6.4.
    protocol Callable {
        @_lifetime(borrow attachment)
        func call(
            _ arguments: borrowing Object,
            in attachment: borrowing ThreadState.Attachment,
        ) throws -> Object
    }
}

// MARK: Object + Buffer

public extension Object {
    @_lifetime(borrow self)
    borrowing func buffer<Element: BitwiseCopyable>(
        as type: Element.Type = Element.self,
        isWritable: Bool = false,
    ) throws -> BufferLease<Element> {
        unsafe try BufferLease(pointer, isWritable: isWritable, in: self)
    }
}

// MARK: Object + Coding

extension Object {
    @_lifetime(borrow owner)
    init<T: Encodable & ~Copyable, Owner: ~Copyable & ~Escapable>(
        encoding value: borrowing T,
        in owner: borrowing Owner,
    ) throws {
        var encoder = Encoder(in: owner)
        try value.encode(to: &encoder)
        self = unsafe try Object(owned: encoder.take(), in: owner)
    }

    public borrowing func decode<T: Decodable & ~Copyable>(
        as type: T.Type = T.self,
    ) throws -> T {
        let decoder = unsafe Decoder(pointer, in: self)
        return try decoder.decode(type)
    }
}

// MARK: Object + Reference

public extension Object {
    borrowing func retain(in context: borrowing Context) throws -> Reference {
        try context.checkAccess()
        return unsafe try context.references.retain(pointer)
    }
}

//
//  Created by Anton Spivak
//

internal import libcpython

/// A reference borrowed from the immutable tuple of an active Python call.
@safe
public struct BorrowedObject: ~Escapable {
    let pointer: UnsafeMutablePointer<PyObject>

    @_lifetime(borrow owner)
    @unsafe
    init<Owner: ~Copyable & ~Escapable>(
        _ pointer: UnsafeMutablePointer<PyObject>,
        in owner: borrowing Owner,
    ) {
        unsafe self.pointer = pointer
    }

    public borrowing func decode<T: Decodable & ~Copyable>(
        as type: T.Type = T.self,
    ) throws -> T {
        let decoder = unsafe Decoder(pointer, in: self)
        return try decoder.decode(type)
    }

    @_lifetime(copy self)
    public borrowing func owned() throws -> Object {
        _ = try InterpreterStorage.requireCurrent()
        unsafe Py_IncRef(pointer)
        return unsafe try Object.take(pointer, inheriting: self)
    }
}

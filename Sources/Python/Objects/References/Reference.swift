//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Reference

/// An owning Python root. Resolve it only in the session generation that created it.
public struct Reference: Sendable {
    final class Storage: Sendable {
        let references: ReferenceStore
        let token: UInt64

        init(references: ReferenceStore, token: UInt64) {
            self.references = references
            self.token = token
        }

        deinit { references.release(token) }
    }

    let storage: Storage

    init(storage: Storage) {
        self.storage = storage
    }

    @_lifetime(borrow context)
    public func resolve(in context: borrowing Context) throws -> Object {
        try context.checkAccess()
        guard context.storage.references === storage.references else {
            throw Self.wrongInterpreter()
        }
        let pointer = unsafe try storage.references.pointer(storage.token)
        unsafe Py_IncRef(pointer)
        return unsafe Object(owned: pointer, in: context)
    }

    static func wrongInterpreter() -> Exception {
        Exception(
            name: "ReferenceError",
            message: "A Python reference cannot be used in a different interpreter.",
        )
    }
}

// MARK: Encodable

extension Reference: Encodable {
    public func encode(to encoder: inout Encoder) throws {
        let state = try InterpreterStorage.requireCurrent()
        guard state.references === storage.references else {
            throw Self.wrongInterpreter()
        }
        let pointer = unsafe try storage.references.pointer(storage.token)
        unsafe Py_IncRef(pointer)
        unsafe try encoder.replace(pointer)
    }
}

// MARK: Decodable

extension Reference: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        let state = try InterpreterStorage.requireCurrent()
        self = unsafe try state.references.retain(decoder.pointer)
    }
}

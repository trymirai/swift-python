//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Reference

/// Keeps a Python object alive in its interpreter generation.
/// Reset, close, or rollback of the creating block invalidates the reference.
public struct Reference: Sendable {
    final class Storage: Sendable {
        let references: Reference.Store
        private let token: UInt64

        init(references: Reference.Store, token: UInt64) {
            self.references = references
            self.token = token
        }

        deinit { references.release(token) }

        @unsafe
        func pointer() throws -> UnsafeMutablePointer<PyObject> {
            unsafe try references.pointer(token)
        }
    }

    let storage: Storage

    init(storage: Storage) {
        self.storage = storage
    }

    @_lifetime(borrow context)
    func resolve(in context: borrowing Context) throws -> Object {
        let current = try context.checkAccess()
        return try object(in: current.references, scopedTo: context)
    }

    @_lifetime(borrow owner)
    private func object<Owner: ~Copyable & ~Escapable>(
        in references: Reference.Store,
        scopedTo owner: borrowing Owner,
    ) throws -> Object {
        guard references === storage.references else {
            throw Self.wrongInterpreter()
        }
        let pointer = unsafe try storage.pointer()
        return unsafe Object.retaining(pointer, in: owner)
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
        let state = try Interpreter.Storage.requireCurrent()
        try encoder.encode(object(in: state.references, scopedTo: self))
    }
}

// MARK: Decodable

extension Reference: Decodable {
    public init(from decoder: borrowing Decoder) throws {
        let state = try Interpreter.Storage.requireCurrent()
        self = unsafe try state.references.retain(decoder.pointer)
    }
}

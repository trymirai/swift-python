//
//  Created by Anton Spivak
//

internal import libcpython

extension Object {
    static func installImporter(in attachment: borrowing PThread.Attachment) throws {
        try check(CPython_InstallEmbeddedImporter(), "Unable to install the embedded importer.")
    }

    @_lifetime(borrow owner)
    static func `import`<Owner: ~Copyable & ~Escapable>(
        module name: String,
        in owner: borrowing Owner,
    ) throws -> Object {
        guard !name.utf8.contains(0) else {
            throw Failure(
                .valueError,
                message: "A Python module name cannot contain NUL.",
            )
        }
        return unsafe try take(PyImport_ImportModule(name), in: owner)
    }

    @_lifetime(borrow owner)
    static func importClass<Owner: ~Copyable & ~Escapable>(
        module: String,
        name: String,
        in owner: borrowing Owner,
    ) throws -> Object {
        let type = try Object.import(module: module, in: owner).value(forAttribute: name)

        guard unsafe PyType_Check(type.pointer) != 0 else {
            throw Failure(
                .typeError,
                message: "Expected \(module).\(name) to be a class.",
            )
        }

        return type
    }

    borrowing func isInstance(of type: borrowing Object) throws -> Bool {
        let result = unsafe PyObject_IsInstance(pointer, type.pointer)
        guard result >= 0 else {
            throw Self.failure("Unable to check the Python object's type.")
        }

        return result != 0
    }
}

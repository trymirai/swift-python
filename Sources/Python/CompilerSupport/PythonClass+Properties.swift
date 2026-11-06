//
//  Created by Anton Spivak
//

internal import libcpython

extension _PythonClass {
    @_documentation(visibility: internal)
    public func _pythonGetProperty<Value: Decodable & ~Copyable>(
        _ key: String,
        as type: Value.Type,
    ) throws -> Value {
        try pythonProperty(key).decode(as: type)
    }

    @_documentation(visibility: internal)
    public func _pythonSetProperty<Value: Encodable & ~Copyable>(
        _ value: borrowing Value,
        forKey key: String,
    ) throws {
        let fields = try pythonFields()
        try fields.set(value, forKey: key)
    }

    @_lifetime(borrow self)
    func pythonProperty(_ key: String) throws -> Object {
        let fields = try pythonFields()
        let key = try Object(encoding: key, in: fields)
        var pointer: UnsafeMutablePointer<PyObject>?
        guard unsafe PyDict_GetItemRef(fields.pointer, key.pointer, &pointer) >= 0 else {
            throw Object.failure("Unable to read a Python property.")
        }
        return unsafe try Object.take(
            pointer ?? Py_GetConstant(UInt32(Py_CONSTANT_NONE)),
            in: self,
        )
    }

    func storePythonProperty(_ object: borrowing Object, forKey key: String) throws {
        let fields = try pythonFields()
        try fields.item(.string(key)).set(object)
    }

    @_lifetime(borrow self)
    private func pythonFields() throws -> Object {
        let context = _pythonContext
        let storage = try context.checkAccess()
        let identity = try pythonIdentity

        let wrapper: Object
        if let weak = identity.wrapper {
            guard let bound = try context.object(weak) else {
                throw Exception(
                    name: "ReferenceError",
                    message: "The Python property has no live wrapper.",
                )
            }
            wrapper = unsafe _overrideLifetime(consume bound, borrowing: self)
        } else {
            guard let registry = storage.classRegistry else {
                throw ClassRegistry.unregistered()
            }
            wrapper = try registry.wrapper(for: self, in: self)
            try storage.retainConstructedWrapper(wrapper)
        }
        return try wrapper.attribute("_swift_fields")
    }
}

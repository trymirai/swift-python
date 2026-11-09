//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Object.Property

public extension Object {
    @_documentation(visibility: internal)
    struct Property<Value: ~Copyable>: Sendable {
        let key: String

        public init(_ key: String) {
            self.key = key
        }
    }
}

extension _PClass {
    @_documentation(visibility: internal)
    public func _pGetProperty<Value: Decodable & ~Copyable>(
        _ property: Object.Property<Value>,
    ) throws -> Value {
        try pPropertyOrNone(property).decode(as: Value.self)
    }

    @_documentation(visibility: internal)
    public func _pSetProperty<Value: Encodable & ~Copyable>(
        _ value: borrowing Value,
        for property: Object.Property<Value>,
    ) throws {
        let fields = try pFields()
        try fields.set(value, forKey: property.key)
    }

    @_lifetime(borrow self)
    private func pProperty<Value: ~Copyable>(_ property: Object.Property<Value>) throws -> Object? {
        let fields = try pFields()
        let key = try Object(encoding: property.key, in: fields)
        var pointer: UnsafeMutablePointer<PyObject>?
        switch unsafe PyDict_GetItemRef(fields.pointer, key.pointer, &pointer) {
        case 0:
            return nil
        case 1:
            return unsafe try Object.take(pointer, in: self)
        default:
            throw Object.failure("Unable to read a Python property.")
        }
    }

    @_lifetime(borrow self)
    func pPropertyOrNone<Value: ~Copyable>(_ property: Object.Property<Value>) throws -> Object {
        if let value = try pProperty(property) {
            return consume value
        }
        return unsafe try Object.take(Py_GetConstant(UInt32(Py_CONSTANT_NONE)), in: self)
    }

    func storePProperty<Value: ~Copyable>(
        _ object: borrowing Object,
        for property: Object.Property<Value>,
    ) throws {
        let fields = try pFields()
        try fields.item(.string(property.key)).set(object)
    }

    @_lifetime(borrow self)
    private func pFields() throws -> Object {
        let storage = try Interpreter.Storage.requireCurrent()
        let identity = _pIdentity

        let wrapper: Object
        if let weak = identity.wrapper {
            try identity.claim(self, in: storage)
            let context = Context(storage: storage)
            guard let bound = try context.object(weak) else {
                throw Exception(
                    name: "ReferenceError",
                    message: "The Python property has no live wrapper.",
                )
            }
            wrapper = unsafe _overrideLifetime(consume bound, borrowing: self)
        } else {
            guard let registry = storage.classRegistry else {
                throw Interpreter.ClassRegistry.unregistered()
            }
            wrapper = try registry.wrapper(for: self, in: self)
            try storage.retainConstructedWrapper(wrapper)
        }
        return try wrapper.attribute("_swift_fields")
    }
}

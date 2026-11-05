//
//  Created by Anton Spivak
//

internal import libcpython

// All Python references in this registry belong to exactly one interpreter generation.
final class ClassRegistry {
    private let definitions: [Module.Class]

    private var typesByKey: [String: Reference] = [:]
    private var keysByTypeAddress: [UInt: String] = [:]
    private var wrapperFactory: Reference?

    private var isInstalled: Bool = false

    init(modules: [Module]) {
        definitions = modules.flatMap(\.classes)
    }

    func register(
        _ type: borrowing Object,
        forKey key: String,
        in storage: InterpreterStorage,
    ) throws {
        guard
            !isInstalled, typesByKey[key] == nil,
            definitions.contains(where: { $0.key == key })
        else {
            throw ExportCatalog.failure("Class registration is closed or invalid.")
        }
        typesByKey[key] = unsafe try storage.references.retain(type.pointer)
        keysByTypeAddress[unsafe UInt(bitPattern: type.pointer)] = key
    }

    func registerWrapperFactory(
        _ function: borrowing Object,
        in storage: InterpreterStorage,
    ) throws {
        guard !isInstalled, wrapperFactory == nil else {
            throw ExportCatalog.failure("Python wrapper registration is closed.")
        }
        wrapperFactory = unsafe try storage.references.retain(function.pointer)
    }

    func finishInstallation() {
        isInstalled = true
    }

    static func unregistered() -> Exception {
        ExportCatalog.failure("The Swift class's module is not installed in this session.")
    }

    private func identity(of instance: any _PythonClass) throws -> InstanceIdentity {
        guard let identity = instance._pythonIdentity as? InstanceIdentity else {
            throw ExportCatalog.failure("Invalid Swift instance identity.")
        }
        return identity
    }

    @_lifetime(borrow owner)
    func makeCapsule<Owner: ~Copyable & ~Escapable>(
        for instance: any _PythonClass,
        in owner: borrowing Owner,
    ) throws -> Object {
        let storage = try InterpreterStorage.requireCurrent()
        guard typesByKey[String(reflecting: Swift.type(of: instance))] != nil
        else {
            throw Self.unregistered()
        }

        let identity = try identity(of: instance)
        try identity.claim(instance, in: storage)
        try identity.beginWrapperConstruction()

        let retained = unsafe Unmanaged.passRetained(instance as AnyObject).toOpaque()
        let capsule = unsafe CPython_NewPeer(retained, { pointer in
            unsafe Unmanaged<AnyObject>.fromOpaque(pointer).release()
        })

        guard let pointer = unsafe capsule else {
            identity.endWrapperConstruction()
            throw Object.failure("Unable to retain a Swift instance.")
        }

        return unsafe Object(owned: pointer, in: owner)
    }

    @_lifetime(borrow owner)
    func wrapper<Owner: ~Copyable & ~Escapable>(
        for instance: any _PythonClass,
        in owner: borrowing Owner,
    ) throws -> Object {
        guard typesByKey[String(reflecting: Swift.type(of: instance))] != nil
        else {
            throw Self.unregistered()
        }

        let context = try Context(in: owner)
        let identity = try identity(of: instance)
        try identity.claim(instance, in: context.storage)

        if let weak = identity.wrapper, let wrapper = try weak.resolve(in: context) {
            // Transfer the scoped result to the caller's attachment lifetime.
            return unsafe Object(owned: wrapper.release(), in: owner)
        }

        guard let wrapperFactory else {
            throw Self.unregistered()
        }

        let function = try wrapperFactory.resolve(in: context)
        let key = try Object(encoding: String(reflecting: Swift.type(of: instance)), in: context)
        let capsule = try makeCapsule(for: instance, in: context)

        do {
            let wrapper = try function.call(key, capsule)
            return unsafe Object(owned: wrapper.release(), in: owner)
        } catch {
            identity.endWrapperConstruction()
            throw error
        }
    }

    @unsafe
    func instance(
        for wrapper: UnsafeMutablePointer<PyObject>,
        validateBinding: Bool = true,
    ) throws -> any _PythonClass {
        let storage = try InterpreterStorage.requireCurrent()
        guard let type = unsafe PyObject_Type(wrapper)
        else {
            throw Object.failure("Unable to read a Python type.")
        }
        defer {
            unsafe Py_DecRef(type)
        }
        guard let key = keysByTypeAddress[UInt(bitPattern: type)]
        else {
            throw ExportCatalog.failure("Expected a registered Swift object.")
        }
        guard let capsule = unsafe PyObject_GetAttrString(wrapper, "_swift_peer")
        else {
            throw Object.failure("The Swift object has not been initialized.")
        }
        defer {
            unsafe Py_DecRef(capsule)
        }
        guard let pointer = unsafe CPython_GetPeer(capsule)
        else {
            throw Object.failure("Invalid Swift object payload.")
        }
        guard
            let instance = unsafe Unmanaged<AnyObject>.fromOpaque(pointer)
                .takeUnretainedValue() as? any _PythonClass,
            String(reflecting: Swift.type(of: instance)) == key
        else {
            throw ExportCatalog.failure("The Swift object payload has a different class.")
        }
        let identity = try identity(of: instance)
        try identity.claim(instance, in: storage)
        if validateBinding {
            let context = try Context(in: key)
            guard
                let weak = identity.wrapper, let bound = try weak.resolve(in: context),
                unsafe bound.pointer == wrapper
            else {
                throw ExportCatalog
                    .failure("The Swift payload belongs to a different Python object.")
            }
        }
        return instance
    }

    func bind(_ object: borrowing Object) throws {
        let context = try Context(in: object)

        let instance = unsafe try instance(for: object.pointer, validateBinding: false)
        let identity = try identity(of: instance)

        guard identity.isConstructingWrapper
        else {
            throw ExportCatalog.failure("The Swift instance is already initialized.")
        }

        if
            let weak = identity.wrapper, let bound = try weak.resolve(in: context),
            unsafe bound.pointer != object.pointer
        {
            throw ExportCatalog.failure("A Swift instance already has a Python wrapper.")
        }

        // Bind superclassKey fields before child fields, retaining only a Python weak reference.
        var key: String? = String(reflecting: Swift.type(of: instance))
        var classHierarchy = [Module.Class]()
        while let current = key, let definition = definitions.first(where: { $0.key == current }) {
            classHierarchy.append(definition)
            key = definition.superclassKey
        }

        for definition in classHierarchy.reversed() {
            for field in definition.fields {
                try field(instance)
            }
        }

        identity.bind(try WeakReference(object, in: context))
        identity.endWrapperConstruction()
    }

    func cancelConstruction(of capsule: borrowing Object) throws {
        guard
            let pointer = unsafe CPython_GetPeer(capsule.pointer),
            let instance = unsafe Unmanaged<AnyObject>.fromOpaque(pointer)
                .takeUnretainedValue() as? any _PythonClass
        else {
            throw Object.failure("Invalid Swift object payload.")
        }
        let identity = try identity(of: instance)
        try identity.claim(instance, in: InterpreterStorage.requireCurrent())
        identity.endWrapperConstruction()
    }
}

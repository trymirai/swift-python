//
//  Created by Anton Spivak
//

internal import libcpython

// All Python references in this registry belong to exactly one interpreter generation.
final class ClassRegistry {
    private let classKeys: Set<String>

    private var typesByKey: [String: Reference] = [:]
    private var keysByTypeAddress: [UInt: String] = [:]
    private var wrapperFactory: Reference?

    private var isInstalled: Bool = false

    init(modules: [Module]) {
        classKeys = Set(modules.flatMap(\.classes).map(\.key))
    }

    func register(
        _ type: borrowing Object,
        forKey key: String,
        in storage: InterpreterStorage,
    ) throws {
        guard
            !isInstalled, typesByKey[key] == nil, classKeys.contains(key)
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

    @_lifetime(borrow context)
    private func makeCapsule(
        for instance: any _PythonClass,
        in context: borrowing Context,
    ) throws -> Object {
        // CPython_NewPeer takes this retain even if allocating the capsule fails.
        let retained = unsafe Unmanaged.passRetained(instance as AnyObject).toOpaque()
        let capsule = unsafe CPython_NewPeer(retained, { pointer in
            unsafe Unmanaged<AnyObject>.fromOpaque(pointer).release()
        })

        guard let pointer = unsafe capsule else {
            throw Object.failure("Unable to retain a Swift instance.")
        }

        return unsafe Object(owned: pointer, in: context)
    }

    @_lifetime(borrow owner)
    func wrapper<Owner: ~Copyable & ~Escapable>(
        for instance: any _PythonClass,
        in owner: borrowing Owner,
    ) throws -> Object {
        let classKey = String(reflecting: Swift.type(of: instance))
        guard typesByKey[classKey] != nil else {
            throw Self.unregistered()
        }

        let storage = try InterpreterStorage.requireCurrent()
        let context = Context(storage: storage)
        let identity = try instance.pythonIdentity
        try identity.claim(instance, in: storage)

        if let weak = identity.wrapper, let wrapper = try weak.resolve(in: context) {
            // Transfer the scoped result to the caller's attachment lifetime.
            return unsafe Object(owned: wrapper.release(), in: owner)
        }

        guard let wrapperFactory else {
            throw Self.unregistered()
        }

        try identity.beginWrapperConstruction()
        defer { identity.endWrapperConstruction() }

        let function = try wrapperFactory.resolve(in: context)
        let key = try Object(encoding: classKey, in: context)
        let capsule = try makeCapsule(for: instance, in: context)
        let wrapper = try function.call(key, capsule)
        return unsafe Object(owned: wrapper.release(), in: owner)
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
        let identity = try instance.pythonIdentity
        try identity.claim(instance, in: storage)
        if validateBinding {
            let context = Context(storage: storage)
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
        let context = try Context()

        let instance = unsafe try instance(for: object.pointer, validateBinding: false)
        let identity = try instance.pythonIdentity

        guard identity.isConstructingWrapper
        else {
            throw ExportCatalog.failure("The Swift instance is already initialized.")
        }

        if let weak = identity.wrapper, case .some = try weak.resolve(in: context) {
            throw ExportCatalog.failure("A Swift instance already has a Python wrapper.")
        }

        identity.bind(try WeakReference(object, in: context))
    }
}

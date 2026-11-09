//
//  Created by Anton Spivak
//

internal import libcpython

extension Interpreter {
    // All Python references in this registry belong to exactly one interpreter generation.
    final class ClassRegistry {
        private let classKeys: Set<String>
        private var isInstalled: Bool = false

        private var typesByKey: [String: Reference] = [:]
        private var keysByTypeAddress: [UInt: String] = [:]
        private var wrapperFactory: Reference?

        private var savedWrappers: [ObjectIdentifier: (Object.Identity, WeakReference?)]?

        init(modules: [Module]) {
            classKeys = Set(modules.flatMap(\.classes).map(\.key))
        }

        func register(
            _ type: borrowing Object,
            forKey key: String,
            in storage: Interpreter.Storage,
        ) throws {
            let address = unsafe UInt(bitPattern: type.pointer)
            guard
                !isInstalled, typesByKey[key] == nil, keysByTypeAddress[address] == nil,
                classKeys.contains(key)
            else {
                throw Module.Catalog.failure("Class registration is closed or invalid.")
            }

            typesByKey[key] = unsafe try storage.references.retain(type.pointer)
            keysByTypeAddress[address] = key
        }

        func registerWrapperFactory(
            _ function: borrowing Object,
            in storage: Interpreter.Storage,
        ) throws {
            guard !isInstalled, wrapperFactory == nil else {
                throw Module.Catalog.failure("Python wrapper registration is closed.")
            }
            wrapperFactory = unsafe try storage.references.retain(function.pointer)
        }

        func finishInstallation() {
            isInstalled = true
        }

        func beginCheckpoint() {
            precondition(savedWrappers == nil)
            savedWrappers = [:]
        }

        func finishCheckpoint(restoring: Bool) {
            guard let saved = exchange(&savedWrappers, with: nil) else {
                preconditionFailure("A Python class checkpoint is not active.")
            }
            if restoring {
                for (identity, wrapper) in saved.values {
                    identity.restoreWrapper(wrapper)
                }
            }
        }

        static func unregistered() -> Exception {
            Module.Catalog.failure("The Swift class's module is not installed in this session.")
        }

        @_lifetime(borrow context)
        private func makeCapsule(
            for instance: any _PClass,
            in context: borrowing Context,
        ) throws -> Object {
            let retained = unsafe Unmanaged.passRetained(instance as AnyObject).toOpaque()
            let capsule = unsafe CPython_NewPeer(retained, { pointer in
                unsafe Unmanaged<AnyObject>.fromOpaque(pointer).release()
            })

            let pointer = unsafe try Object.require(capsule, "Unable to retain a Swift instance.")
            return unsafe Object(owned: pointer, in: context)
        }

        @_lifetime(borrow owner)
        func wrapper<Owner: ~Copyable & ~Escapable>(
            for instance: any _PClass,
            in owner: borrowing Owner,
        ) throws -> Object {
            let classKey = String(reflecting: Swift::type(of: instance))
            guard typesByKey[classKey] != nil else {
                throw Self.unregistered()
            }

            let storage = try Interpreter.Storage.requireCurrent()
            let identity = instance._pIdentity
            try identity.claim(instance, in: storage)

            let context = Context(storage: storage)
            if let weak = identity.wrapper, let wrapper = try weak.resolve(in: context) {
                // Transfer the scoped result to the caller's attachment lifetime.
                return unsafe Object(owned: wrapper.release(), in: owner)
            }

            guard let wrapperFactory else {
                throw Self.unregistered()
            }

            rememberWrapper(for: identity)
            try identity.beginWrapperConstruction()
            defer { identity.endWrapperConstruction() }

            let function = try wrapperFactory.resolve(in: context)
            let key = try Object(encoding: classKey, in: context)
            let capsule = try makeCapsule(for: instance, in: context)

            let wrapper = try function.call(key, capsule)
            return unsafe Object(owned: wrapper.release(), in: owner)
        }

        private func rememberWrapper(for identity: Object.Identity) {
            guard savedWrappers != nil else {
                return
            }
            let id = ObjectIdentifier(identity)
            if savedWrappers?[id] == nil {
                savedWrappers?[id] = (identity, identity.wrapper)
            }
        }

        @unsafe
        func instance(for wrapper: UnsafeMutablePointer<PyObject>) throws -> any _PClass {
            let storage = try Interpreter.Storage.requireCurrent()
            let instance = unsafe try peer(of: wrapper, in: storage)
            let context = Context(storage: storage)
            guard
                let weak = instance._pIdentity.wrapper,
                let bound = try weak.resolve(in: context),
                unsafe bound.pointer == wrapper
            else {
                throw Module.Catalog
                    .failure("The Swift payload belongs to a different Python object.")
            }
            return instance
        }

        @unsafe
        private func peer(
            of wrapper: UnsafeMutablePointer<PyObject>,
            in storage: Interpreter.Storage,
        ) throws -> any _PClass {
            let type = unsafe try Object.take(PyObject_Type(wrapper), in: storage)
            guard let key = keysByTypeAddress[unsafe UInt(bitPattern: type.pointer)] else {
                throw Module.Catalog.failure("Expected a registered Swift object.")
            }

            let capsule = unsafe try Object.take(
                PyObject_GetAttrString(wrapper, "_swift_peer"),
                in: storage,
            )
            let pointer = unsafe try Object.require(
                CPython_GetPeer(capsule.pointer),
                "Invalid Swift object payload.",
            )

            guard
                let instance = unsafe Unmanaged<AnyObject>.fromOpaque(pointer)
                    .takeUnretainedValue() as? any _PClass,
                String(reflecting: Swift::type(of: instance)) == key
            else {
                throw Module.Catalog.failure("The Swift object payload has a different class.")
            }
            try instance._pIdentity.claim(instance, in: storage)
            return instance
        }

        func bind(_ object: borrowing Object) throws {
            let storage = try Interpreter.Storage.requireCurrent()
            let context = Context(storage: storage)
            let instance = unsafe try peer(of: object.pointer, in: storage)
            try instance._pIdentity.bind(WeakReference(object, in: context))
        }
    }
}

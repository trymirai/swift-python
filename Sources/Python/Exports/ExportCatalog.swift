//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - ExportCatalog

struct ExportCatalog {
    private var exports: [ExportDefinition] = []

    private init() {
        var providers = [any _ExportProvider.Type]()
        withUnsafeMutablePointer(to: &providers) { collector in
            unsafe CPython_DiscoverExports(UnsafeMutableRawPointer(collector)) {
                let provider = unsafe $1
                    .assumingMemoryBound(to: (any _ExportProvider.Type).self)
                    .pointee
                unsafe $0.assumingMemoryBound(to: [any _ExportProvider.Type].self)
                    .pointee
                    .append(provider)
            }
        }

        var seen = Set<ObjectIdentifier>()

        for provider in providers {
            guard seen.insert(ObjectIdentifier(provider)).inserted else {
                continue
            }
            provider._pythonExport(to: &self)
        }
    }

    static func resolve(
        _ moduleTypes: [any ModuleHost.Type],
        instances: [any ModuleHost] = [],
        definitions: [Module] = [],
    ) throws -> [Module] {
        guard !moduleTypes.isEmpty || !instances.isEmpty else {
            return definitions
        }
        let catalog = Self()
        var selectedModules = [ObjectIdentifier: any ModuleHost.Type]()
        var configuredInstances = [ObjectIdentifier: any ModuleHost]()

        for type in moduleTypes {
            selectedModules[ObjectIdentifier(type)] = type
        }

        for instance in instances {
            let type = Swift.type(of: instance)
            let key = ObjectIdentifier(type)
            guard configuredInstances[key] == nil
            else {
                throw Self.failure("A module instance was provided twice.")
            }
            selectedModules[key] = type
            configuredInstances[key] = instance
        }

        var classes = try catalog.makeClassDefinitions()
        catalog.includeSuperclassModules(in: &selectedModules, classes: classes)
        try catalog.attachMembers(to: &classes)

        var result = definitions
        var names = Set(definitions.map(\.name))

        let selectedModulesValues = selectedModules
            .values
            .sorted(by: { $0._pythonModuleName < $1._pythonModuleName })

        for type in selectedModulesValues {
            let name = type._pythonModuleName
            guard names.insert(name).inserted else {
                throw Self.failure("Python module '\(name)' was declared twice.")
            }

            let instance = try configuredInstances[ObjectIdentifier(type)]
                ?? type._pythonDefaultInstance()

            result.append(try catalog.makeModule(
                for: type,
                name: name,
                instance: instance,
                classes: classes,
            ))
        }
        return result
    }

    static func failure(_ message: String) -> Exception {
        Exception(name: "TypeError", message: message)
    }

    private func makeClassDefinitions() throws -> [ObjectIdentifier: Module.Class] {
        var classes = [ObjectIdentifier: Module.Class]()
        for case let .classDefinition(definition) in exports {
            guard classes.updateValue(definition, forKey: ObjectIdentifier(definition.type)) == nil
            else {
                throw Self.failure("A Swift class was exported twice.")
            }
        }

        for key in Array(classes.keys) {
            var superclass: AnyClass? = _getSuperclass(classes[key]!.type)
            while let candidate = superclass {
                if let definition = classes[ObjectIdentifier(candidate)] {
                    classes[key]!.superclassKey = definition.key
                    break
                }
                superclass = _getSuperclass(candidate)
            }
        }
        return classes
    }

    private func includeSuperclassModules(
        in selectedModules: inout [ObjectIdentifier: any ModuleHost.Type],
        classes: [ObjectIdentifier: Module.Class],
    ) {
        // A selected subclass brings in its exported Swift bases and their modules.
        var didIncludeModule = true
        while didIncludeModule {
            didIncludeModule = false
            for definition in classes.values
                where selectedModules[ObjectIdentifier(definition.module)] != nil
            {
                if
                    let superclassKey = definition.superclassKey,
                    let parent = classes.values.first(where: { $0.key == superclassKey }),
                    selectedModules[ObjectIdentifier(parent.module)] == nil
                {
                    selectedModules[ObjectIdentifier(parent.module)] = parent.module
                    didIncludeModule = true
                }
            }
        }
    }

    private func attachMembers(to classes: inout [ObjectIdentifier: Module.Class]) throws {
        for export in exports {
            switch export {
            case let .method(owner, function):
                classes[owner]?.methods.append(function)
            case let .initializer(owner, function):
                if classes[owner]?.initializer != nil {
                    throw Self.failure("A class has more than one PythonInit.")
                }
                classes[owner]?.initializer = function
            case let .property(owner, property):
                classes[owner]?.properties.append(property)
            case let .field(owner, field):
                classes[owner]?.fields.append(field)
            default:
                break
            }
        }
    }

    private func makeModule(
        for type: any ModuleHost.Type,
        name: String,
        instance: (any ModuleHost)?,
        classes: [ObjectIdentifier: Module.Class],
    ) throws -> Module {
        let key = ObjectIdentifier(type)
        var functions = [Module.Function]()
        for case let .function(owner, makeFunction) in exports
            where ObjectIdentifier(owner) == key
        {
            functions.append(try makeFunction(instance))
        }

        functions.sort { $0.name < $1.name }
        var names = Set<String>()
        for function in functions {
            guard names.insert(function.name).inserted else {
                throw Self.failure("Python export '\(name).\(function.name)' was declared twice.")
            }
        }

        var module = Module(
            name,
            documentation: type._pythonModuleDocumentation,
            functions: functions,
        )

        module.classes = classes.values
            .filter { ObjectIdentifier($0.module) == key }
            .sorted { $0.key < $1.key }
        for index in module.classes.indices {
            guard names.insert(module.classes[index].name).inserted else {
                throw Self.failure("A class and another export have the same Python name.")
            }
            try module.classes[index].validateMembers()
        }
        return module
    }
}

// MARK: _ExportSink

extension ExportCatalog: _ExportSink {
    mutating func addFunction(
        module: any ModuleHost.Type,
        makeFunction: @escaping @Sendable ((any ModuleHost)?) throws -> Module.Function,
    ) {
        exports.append(.function(module: module, makeFunction: makeFunction))
    }

    mutating func addClass<Instance: _PythonClass>(
        _ type: Instance.Type,
        module: any ModuleHost.Type,
        name: String,
        documentation: String?,
    ) {
        exports.append(.classDefinition(Module.Class(
            type: type,
            module: module,
            name: name,
            documentation: documentation,
        )))
    }

    mutating func addMethod<Instance: _PythonClass>(
        _ type: Instance.Type,
        function: Module.Function,
    ) {
        exports.append(.method(ObjectIdentifier(type), function))
    }

    mutating func addInitializer<Instance: _PythonClass>(
        _ type: Instance.Type,
        function: Module.Function,
    ) {
        exports.append(.initializer(ObjectIdentifier(type), function))
    }

    mutating func addProperty<Instance: _PythonClass>(
        _ type: Instance.Type,
        name: String,
        documentation: String?,
        getter: @escaping @Sendable (Instance, borrowing Context, inout Encoder) throws -> Void,
        setter: (@Sendable (Instance, borrowing Decoder, borrowing Context) throws -> Void)?,
    ) {
        let getterFunction = Module.Function(
            "get_" + name,
            parameters: [.init("self")],
            call: { arguments, context, encoder in
                try getter(arguments.receiver(as: type), context, &encoder)
            },
        )
        let setterFunction = setter.map { setter in
            Module.Function(
                "set_" + name,
                parameters: [.init("self"), .init("value")],
                call: { arguments, context, encoder in
                    let decoder = unsafe try Decoder(arguments.element(1), in: arguments)
                    try setter(arguments.receiver(as: type), decoder, context)
                    try encoder.encodeNil()
                },
            )
        }
        exports.append(.property(
            ObjectIdentifier(type),
            .init(
                name: name,
                documentation: documentation,
                getter: getterFunction,
                setter: setterFunction,
            ),
        ))
    }

    mutating func addReference<Instance: _PythonClass, Value>(
        _ type: Instance.Type,
        name: String,
        field: @escaping @Sendable (Instance) -> Field<Value>,
    ) {
        exports.append(.field(ObjectIdentifier(type), { instance in
            guard
                let instance = instance as? Instance,
                let identity = instance._pythonIdentity as? InstanceIdentity
            else {
                throw Self.failure("Invalid Python field owner.")
            }
            try field(instance).bind(to: identity, key: String(reflecting: type) + "." + name)
        }))
    }
}

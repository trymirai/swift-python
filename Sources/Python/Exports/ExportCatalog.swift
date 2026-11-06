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
        definitions: [Module] = [],
    ) throws -> [Module] {
        guard !moduleTypes.isEmpty else {
            return definitions
        }
        let catalog = Self()
        var selectedModules = [ObjectIdentifier: any ModuleHost.Type]()

        for type in moduleTypes {
            selectedModules[ObjectIdentifier(type)] = type
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

            result.append(try catalog.makeModule(
                for: type,
                name: name,
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

        for (key, definition) in classes {
            var superclass: AnyClass? = _getSuperclass(definition.type)
            while let candidate = superclass {
                if let base = classes[ObjectIdentifier(candidate)] {
                    classes[key]?.superclass = base.type
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
        let classesByModule = Dictionary(grouping: classes.values) {
            ObjectIdentifier($0.module)
        }

        var pending = Array(selectedModules.keys)
        while let module = pending.popLast() {
            // Including a module also includes the bases of its other classes.
            for definition in classesByModule[module, default: []] {
                guard
                    let superclass = definition.superclass,
                    let parent = classes[ObjectIdentifier(superclass)]
                else {
                    continue
                }
                let parentModule = ObjectIdentifier(parent.module)
                if selectedModules[parentModule] == nil {
                    selectedModules[parentModule] = parent.module
                    pending.append(parentModule)
                }
            }
        }
    }

    private func attachMembers(to classes: inout [ObjectIdentifier: Module.Class]) throws {
        for export in exports {
            switch export {
            case let .method(owner, function):
                guard !function.parameters.contains(where: \.isInjected) else {
                    throw Self.failure("An exported method uses the class's stored Context.")
                }
                classes[owner]?.methods.append(function)
            case let .initializer(owner, function):
                guard function.parameters.count(where: \.isInjected) == 1 else {
                    throw Self.failure("A PythonInit requires one Context parameter.")
                }
                if classes[owner]?.initializer != nil {
                    throw Self.failure("A class has more than one PythonInit.")
                }
                classes[owner]?.initializer = function
            case let .property(owner, property):
                classes[owner]?.properties.append(property)
            default:
                break
            }
        }
    }

    private func makeModule(
        for type: any ModuleHost.Type,
        name: String,
        classes: [ObjectIdentifier: Module.Class],
    ) throws -> Module {
        let key = ObjectIdentifier(type)
        var functions = [Module.Function]()
        for case let .function(owner, function) in exports
            where ObjectIdentifier(owner) == key
        {
            guard !function.parameters.contains(where: \.isInjected) else {
                throw Self.failure("A module function cannot take a Python Context.")
            }
            functions.append(function)
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
        function: _ExportFunction,
    ) {
        exports.append(.function(module: module, function: function))
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

    mutating func addStoredProperty<
        Instance: _PythonClass,
        Value: Decodable & SendableMetatype & ~Copyable,
    >(
        _ type: Instance.Type,
        name: String,
        key: String,
        documentation: String?,
        as valueType: Value.Type,
        isReadOnly: Bool,
    ) {
        let setter: (@Sendable (Instance, borrowing Decoder, borrowing Context) throws -> Void)? =
            if isReadOnly {
                nil
            } else {
                { instance, decoder, _ in
                    _ = try decoder.decode(valueType)
                    let object = try decoder.object()
                    try instance.storePythonProperty(object, forKey: key)
                }
            }
        addProperty(
            type,
            name: name,
            documentation: documentation,
            getter: { instance, _, encoder in
                try encoder.encode(instance.pythonProperty(key))
            },
            setter: setter,
        )
    }
}

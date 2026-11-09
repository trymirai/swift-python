//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Module.Catalog

extension Module {
    struct Catalog {
        private enum Entry {
            case classDefinition(Module.Class)

            case method(ObjectIdentifier, Module.Function)
            case initializer(ObjectIdentifier, Module.Function)
            case property(ObjectIdentifier, Module.Class.Property)

            case function(
                module: any ModuleHost.Type,
                function: _ExportFunction,
            )
        }

        private var exports: [Entry] = []

        private init() {
            var seen = Set<ObjectIdentifier>()
            for provider in Self.discoverProviders() {
                guard seen.insert(ObjectIdentifier(provider)).inserted else {
                    continue
                }
                provider._pExport(to: &self)
            }
        }

        private static func discoverProviders() -> [any _ExportProvider.Type] {
            var providers = [any _ExportProvider.Type]()
            withUnsafeMutablePointer(to: &providers) { collector in
                let context = UnsafeMutableRawPointer(collector)
                unsafe CPython_DiscoverExports(context) { collector, type in
                    let provider = unsafe type
                        .assumingMemoryBound(to: (any _ExportProvider.Type).self)
                        .pointee
                    unsafe collector.assumingMemoryBound(to: [any _ExportProvider.Type].self)
                        .pointee
                        .append(provider)
                }
            }

            return providers
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
            try catalog.attachMembers(to: &classes)

            let classesByModule = Dictionary(grouping: classes.values) {
                ObjectIdentifier($0.module)
            }
            Self.includeSuperclassModules(
                in: &selectedModules,
                classes: classes,
                classesByModule: classesByModule,
            )

            return try assembleModules(
                selectedModules.values,
                addingTo: definitions,
                functionsByModule: catalog.functionsByModule(in: selectedModules),
                classesByModule: classesByModule,
            )
        }

        private static func assembleModules(
            _ selected: some Sequence<any ModuleHost.Type>,
            addingTo definitions: [Module],
            functionsByModule: [ObjectIdentifier: [Module.Function]],
            classesByModule: [ObjectIdentifier: [Module.Class]],
        ) throws -> [Module] {
            var result = definitions
            var names = Set(definitions.map(\.name))
            let sortedModules = selected.sorted { $0._pModuleName < $1._pModuleName }
            for type in sortedModules {
                let name = type._pModuleName
                guard names.insert(name).inserted else {
                    throw Self.failure("Python module '\(name)' was declared twice.")
                }

                let key = ObjectIdentifier(type)
                result.append(try Self.makeModule(
                    type,
                    name: name,
                    functions: functionsByModule[key, default: []],
                    classes: classesByModule[key, default: []],
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
                guard
                    classes
                        .updateValue(definition, forKey: ObjectIdentifier(definition.type)) == nil
                else {
                    throw Self.failure("A Swift class was exported twice.")
                }
            }

            // Walk through unexported Swift bases to find the Python superclass.
            func exportedSuperclass(of type: AnyClass) -> (any _PClass.Type)? {
                var superclass: AnyClass? = _getSuperclass(type)
                while let candidate = superclass {
                    if let base = classes[ObjectIdentifier(candidate)] {
                        return base.type
                    }
                    superclass = _getSuperclass(candidate)
                }
                return nil
            }

            for (key, definition) in classes {
                if let superclass = exportedSuperclass(of: definition.type) {
                    classes[key]?.superclass = superclass
                }
            }
            return classes
        }

        private static func includeSuperclassModules(
            in selectedModules: inout [ObjectIdentifier: any ModuleHost.Type],
            classes: [ObjectIdentifier: Module.Class],
            classesByModule: [ObjectIdentifier: [Module.Class]],
        ) {
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

        private func functionsByModule(
            in modules: [ObjectIdentifier: any ModuleHost.Type],
        ) -> [ObjectIdentifier: [Module.Function]] {
            var functions = [ObjectIdentifier: [Module.Function]]()
            for case let .function(owner, function) in exports {
                let key = ObjectIdentifier(owner)
                if modules[key] != nil {
                    functions[key, default: []].append(function)
                }
            }
            return functions
        }

        private static func makeModule(
            _ type: any ModuleHost.Type,
            name: String,
            functions: [Module.Function],
            classes: [Module.Class],
        ) throws -> Module {
            guard !functions.contains(where: { $0.parameters.contains(where: \.isInjected) }) else {
                throw failure("A module function cannot take a Python Context.")
            }

            let functions = functions.sorted { $0.name < $1.name }
            var names = Set<String>()
            for function in functions {
                guard names.insert(function.name).inserted else {
                    throw Self
                        .failure("Python export '\(name).\(function.name)' was declared twice.")
                }
            }

            var module = Module(
                name,
                documentation: type._pModuleDocumentation,
                functions: functions,
            )

            module.classes = classes.sorted { $0.key < $1.key }
            for index in module.classes.indices {
                guard names.insert(module.classes[index].name).inserted else {
                    throw Self.failure("A class and another export have the same Python name.")
                }
                try module.classes[index].validateMembers()
            }
            return module
        }
    }
}

// MARK: - Module.Catalog + _ExportSink

extension Module.Catalog: _ExportSink {
    mutating func addFunction(
        module: any ModuleHost.Type,
        function: _ExportFunction,
    ) {
        exports.append(.function(module: module, function: function))
    }

    mutating func addClass<Instance: _PClass>(
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

    mutating func addMethod<Instance: _PClass>(
        _ type: Instance.Type,
        function: Module.Function,
    ) {
        exports.append(.method(ObjectIdentifier(type), function))
    }

    mutating func addInitializer<Instance: _PClass>(
        _ type: Instance.Type,
        function: Module.Function,
    ) {
        exports.append(.initializer(ObjectIdentifier(type), function))
    }

    mutating func addProperty<Instance: _PClass>(
        _ type: Instance.Type,
        name: String,
        documentation: String?,
        getter: @escaping @Sendable (Instance, borrowing Context, inout Encoder) throws -> Void,
        setter: (@Sendable (Instance, borrowing Decoder, borrowing Context) throws -> Void)?,
    ) {
        let getterFunction = Module.Function(
            "get_" + name,
            parameters: [.receiver],
            call: { arguments, context, encoder in
                try getter(arguments.receiver(as: type), context, &encoder)
            },
        )

        let setterFunction = setter.map { setter in
            Module.Function(
                "set_" + name,
                parameters: [.receiver, .init("value")],
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
        Instance: _PClass,
        Value: Decodable & SendableMetatype & ~Copyable,
    >(
        _ type: Instance.Type,
        name: String,
        property: Object.Property<Value>,
        documentation: String?,
        isReadOnly: Bool,
    ) {
        let setter: (@Sendable (Instance, borrowing Decoder, borrowing Context) throws -> Void)? =
            if isReadOnly {
                nil
            } else {
                { instance, decoder, _ in
                    _ = try decoder.decode(Value.self)
                    let object = try decoder.object()
                    try instance.storePProperty(object, for: property)
                }
            }
        addProperty(
            type,
            name: name,
            documentation: documentation,
            getter: { instance, _, encoder in
                try encoder.encode(instance.pPropertyOrNone(property))
            },
            setter: setter,
        )
    }
}

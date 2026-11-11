//
//  Created by Anton Spivak
//

// MARK: - Module.Plan

extension Module {
    struct Plan {
        let metadata: [Metadata]
        let functions: [Function]

        init(_ modules: [Module]) {
            var functions = [Function]()

            func add(_ function: Function) -> Metadata.Function {
                let id = Function.ID(rawValue: functions.count)
                functions.append(function)
                return Metadata.Function(value: function, id: id)
            }

            func addProperty(_ property: Module.Class.Property) -> Metadata.Property {
                Metadata.Property(
                    value: property,
                    getter: add(property.getter),
                    setter: property.setter.map(add),
                )
            }

            func addClass(_ type: Module.Class) -> Metadata.Class {
                Metadata.Class(
                    value: type,
                    initializer: type.initializer.map(add),
                    methods: type.methods.map(add),
                    properties: type.properties.map(addProperty),
                )
            }

            metadata = modules.map { module in
                Metadata(
                    module: module,
                    functions: module.functions.map(add),
                    classes: module.classes.map(addClass),
                )
            }
            self.functions = functions
        }
    }
}

// MARK: - Module.Metadata

// The positional fields below match the records read by _swift_python_runtime.exports.
extension Module {
    struct Metadata {
        let module: Module
        let functions: [Function]
        let classes: [Class]
    }
}

// MARK: - Module.Metadata + Encodable

extension Module.Metadata: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(module.name, at: 0)
        try encoder.encode(module.documentation, at: 1)
        try encoder.encode(module.source, at: 2)

        try encoder.encode(functions, at: 3)
        try encoder.encode(classes, at: 4)
    }
}

// MARK: - Module.Metadata.Class

extension Module.Metadata {
    struct Class {
        let value: Module.Class

        let initializer: Function?
        let methods: [Function]
        let properties: [Property]
    }
}

// MARK: - Module.Metadata.Class + Encodable

extension Module.Metadata.Class: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(value.key, at: 0)
        try encoder.encode(value.superclass.map { String(reflecting: $0) }, at: 1)
        try encoder.encode(value.name, at: 2)
        try encoder.encode(value.documentation, at: 3)

        try encoder.encode(initializer, at: 4)
        try encoder.encode(methods, at: 5)
        try encoder.encode(properties, at: 6)
    }
}

// MARK: - Module.Metadata.Function

extension Module.Metadata {
    struct Function {
        let value: Module.Function
        let id: Module.Function.ID
    }
}

// MARK: - Module.Metadata.Function + Encodable

extension Module.Metadata.Function: Encodable {
    func encode(to encoder: inout Encoder) throws {
        let isAsynchronous = switch value.body {
        case .synchronous:
            false
        case .asynchronous:
            true
        }

        try encoder.encode(value.name, at: 0)
        try encoder.encode(value.documentation, at: 1)
        try encoder.encode(value.returnAnnotation, at: 2)
        try encoder.encode(isAsynchronous, at: 3)

        let parameters = value.parameters
            .filter { !$0.isInjected }
            .map(Module.Metadata.Parameter.init(value:))
        try encoder.encode(parameters, at: 4)
        try encoder.encode(value.usesSwiftBinding, at: 5)
        try encoder.encode(id.rawValue, at: 6)
    }
}

// MARK: - Module.Metadata.Parameter

private extension Module.Metadata {
    struct Parameter {
        let value: Module.Function.Parameter
    }
}

// MARK: - Module.Metadata.Parameter + Encodable

extension Module.Metadata.Parameter: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(value.name, at: 0)
        try encoder.encode(value.annotation, at: 1)
        try encoder.encode(!value.defaultValue.isRequired, at: 2)
        try encoder.encode(value.defaultValue.literal, at: 3)
    }
}

// MARK: - Module.Metadata.Property

extension Module.Metadata {
    struct Property {
        let value: Module.Class.Property
        let getter: Function
        let setter: Function?
    }
}

// MARK: - Module.Metadata.Property + Encodable

extension Module.Metadata.Property: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(value.name, at: 0)
        try encoder.encode(value.documentation, at: 1)
        try encoder.encode(getter, at: 2)
        try encoder.encode(setter, at: 3)
    }
}

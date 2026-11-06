//
//  Created by Anton Spivak
//

@_documentation(visibility: internal)
public protocol _ExportSink {
    mutating func addFunction(
        module: any ModuleHost.Type,
        function: _ExportFunction,
    )

    mutating func addClass<Instance: _PClass>(
        _ type: Instance.Type,
        module: any ModuleHost.Type,
        name: String,
        documentation: String?,
    )

    mutating func addMethod<Instance: _PClass>(
        _ type: Instance.Type,
        function: _ExportFunction,
    )

    mutating func addInitializer<Instance: _PClass>(
        _ type: Instance.Type,
        function: _ExportFunction,
    )

    mutating func addProperty<Instance: _PClass>(
        _ type: Instance.Type,
        name: String,
        documentation: String?,
        getter: @escaping @Sendable (Instance, borrowing Context, inout Encoder) throws -> Void,
        setter: (@Sendable (Instance, borrowing Decoder, borrowing Context) throws -> Void)?,
    )

    mutating func addStoredProperty<
        Instance: _PClass,
        Value: Decodable & SendableMetatype & ~Copyable,
    >(
        _ type: Instance.Type,
        name: String,
        property: Object.Property<Value>,
        documentation: String?,
        isReadOnly: Bool,
    )
}

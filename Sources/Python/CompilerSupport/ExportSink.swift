//
//  Created by Anton Spivak
//

@_documentation(visibility: internal)
public protocol _ExportSink {
    mutating func addFunction(
        module: any ModuleHost.Type,
        function: _ExportFunction,
    )

    mutating func addClass<Instance: _PythonClass>(
        _ type: Instance.Type,
        module: any ModuleHost.Type,
        name: String,
        documentation: String?,
    )

    mutating func addMethod<Instance: _PythonClass>(
        _ type: Instance.Type,
        function: _ExportFunction,
    )

    mutating func addInitializer<Instance: _PythonClass>(
        _ type: Instance.Type,
        function: _ExportFunction,
    )

    mutating func addProperty<Instance: _PythonClass>(
        _ type: Instance.Type,
        name: String,
        documentation: String?,
        getter: @escaping @Sendable (Instance, borrowing Context, inout Encoder) throws -> Void,
        setter: (@Sendable (Instance, borrowing Decoder, borrowing Context) throws -> Void)?,
    )

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
    )
}

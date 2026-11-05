//
//  Created by Anton Spivak
//

@_documentation(visibility: internal)
public protocol _ExportSink {
    mutating func addFunction(
        module: any ModuleHost.Type,
        makeFunction: @escaping @Sendable ((any ModuleHost)?) throws -> Module.Function,
    )

    mutating func addClass<Instance: _PythonClass>(
        _ type: Instance.Type,
        module: any ModuleHost.Type,
        name: String,
        documentation: String?,
    )

    mutating func addMethod<Instance: _PythonClass>(
        _ type: Instance.Type,
        function: Module.Function,
    )

    mutating func addInitializer<Instance: _PythonClass>(
        _ type: Instance.Type,
        function: Module.Function,
    )

    mutating func addProperty<Instance: _PythonClass>(
        _ type: Instance.Type,
        name: String,
        documentation: String?,
        getter: @escaping @Sendable (Instance, borrowing Context, inout Encoder) throws -> Void,
        setter: (@Sendable (Instance, borrowing Decoder, borrowing Context) throws -> Void)?,
    )

    mutating func addReference<Instance: _PythonClass, Value>(
        _ type: Instance.Type,
        name: String,
        field: @escaping @Sendable (Instance) -> Field<Value>,
    )
}

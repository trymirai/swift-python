//
//  Created by Anton Spivak
//

enum ExportDefinition {
    case classDefinition(Module.Class)

    case method(ObjectIdentifier, Module.Function)
    case initializer(ObjectIdentifier, Module.Function)

    case property(ObjectIdentifier, Module.Class.Property)
    case field(ObjectIdentifier, @Sendable (any _PythonClass) throws -> Void)

    case function(
        module: any ModuleHost.Type,
        makeFunction: @Sendable ((any ModuleHost)?) throws -> Module.Function,
    )
}

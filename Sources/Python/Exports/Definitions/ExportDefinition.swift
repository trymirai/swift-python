//
//  Created by Anton Spivak
//

enum ExportDefinition {
    case classDefinition(Module.Class)

    case method(ObjectIdentifier, Module.Function)
    case initializer(ObjectIdentifier, Module.Function)

    case property(ObjectIdentifier, Module.Class.Property)
    case function(
        module: any ModuleHost.Type,
        function: _ExportFunction,
    )
}

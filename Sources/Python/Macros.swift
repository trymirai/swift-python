//
//  Created by Anton Spivak
//

/// Defines an importable module that the host selects through `modules`.
///
/// Optional source runs in the module's namespace after Swift exports are installed
/// and before session startup.
@attached(member, names: named(_pModuleName), named(_pModuleDocumentation), named(_pModuleSource))
@attached(extension, conformances: ModuleHost)
public macro PythonModule(
    _ name: String,
    documentation: String? = nil,
    source: String? = nil,
) = #externalMacro(
    module: "PythonMacros",
    type: "PythonModuleMacro",
)

/// Exports the method as a Python function, preserving asynchronous calls.
/// An optional first unlabeled `Context` parameter receives the current Swift callback context.
@attached(peer, names: prefixed(__p_))
public macro PythonFunction(
    _ name: String? = nil,
    documentation: String? = nil,
) = #externalMacro(
    module: "PythonMacros",
    type: "PythonFunctionMacro",
)

/// Exports a Swift class. The nearest exported Swift ancestor supplies its Python base.
@attached(member, names: prefixed(__p_), named(__p_identity))
@attached(memberAttribute)
@attached(
    extension,
    conformances: _PClass,
    names: named(_pIdentity)
)
public macro PythonClass(
    _ name: String? = nil,
    module: (any ModuleHost.Type)? = nil,
    documentation: String? = nil,
) = #externalMacro(module: "PythonMacros", type: "PythonClassMacro")

/// Selects a synchronous, non-failable initializer. It may receive a `Context` parameter.
@attached(peer, names: prefixed(__p_))
public macro PythonInit(documentation: String? = nil) = #externalMacro(
    module: "PythonMacros",
    type: "PythonInitMacro",
)

/// Exports a Swift property. A stored var uses the Python wrapper for its storage.
@attached(peer, names: prefixed(__p_), prefixed(`$`))
public macro PythonProperty(
    _ name: String? = nil,
    isReadOnly: Bool = false,
    documentation: String? = nil,
) = #externalMacro(module: "PythonMacros", type: "PythonPropertyMacro")

@_documentation(visibility: internal)
@attached(accessor, names: named(get))
public macro _PythonStoredProperty() = #externalMacro(
    module: "PythonMacros",
    type: "PythonStoredPropertyMacro",
)

//
//  Created by Anton Spivak
//

/// Synthesizes a module from the methods marked with `PythonFunction`.
@attached(
    member,
    names: named(_pythonModuleName),
    named(_pythonModuleDocumentation),
    named(_pythonDefaultInstance)
)
@attached(extension, conformances: ModuleHost)
public macro PythonModule(_ name: String, documentation: String? = nil) = #externalMacro(
    module: "PythonMacros",
    type: "PythonModuleMacro",
)

/// Exports the method as a Python function, preserving asynchronous calls.
@attached(peer, names: prefixed(__python_))
public macro PythonFunction(
    _ name: String? = nil,
    module: (any ModuleHost.Type)? = nil,
    documentation: String? = nil,
) = #externalMacro(
    module: "PythonMacros",
    type: "PythonFunctionMacro",
)

/// Exports a Swift class. Its base class is inferred from Swift inheritance.
@attached(member, names: prefixed(__python_), named(__python_identity))
@attached(extension, conformances: _PythonClass, names: named(_pythonIdentity))
public macro PythonClass(
    _ name: String? = nil,
    module: (any ModuleHost.Type)? = nil,
    documentation: String? = nil,
) = #externalMacro(module: "PythonMacros", type: "PythonClassMacro")

/// Selects the synchronous, non-failable initializer callable from Python.
@attached(peer, names: prefixed(__python_))
public macro PythonInit(documentation: String? = nil) = #externalMacro(
    module: "PythonMacros",
    type: "PythonInitMacro",
)

/// Exports a stored or computed instance property. Private setters remain read-only.
@attached(peer, names: prefixed(__python_))
public macro PythonProperty(
    _ name: String? = nil,
    isReadOnly: Bool = false,
    documentation: String? = nil,
) = #externalMacro(module: "PythonMacros", type: "PythonPropertyMacro")

/// Binds a stored Field token to the Python wrapper's GC-visible field storage.
@attached(peer, names: prefixed(__python_))
public macro PythonReference() = #externalMacro(
    module: "PythonMacros",
    type: "PythonReferenceMacro",
)

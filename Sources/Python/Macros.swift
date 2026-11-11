//
//  Created by Anton Spivak
//

/// Defines an importable module that the host selects through `modules`.
///
/// Optional source runs in the module's namespace after Swift exports are installed
/// and before session startup. Imported types in the exports supply lazy
/// imports for the source where their module names are available.
@attached(member, names: named(_pModuleName), named(_pModuleDocumentation), named(_pModuleSource))
@attached(extension, conformances: ModuleHost)
public macro PythonExportedModule(
    _ name: String,
    documentation: String? = nil,
    source: String? = nil,
) = #externalMacro(
    module: "PythonMacros",
    type: "PythonExportedModuleMacro",
)

/// Exports a Swift class. The nearest exported Swift ancestor supplies its Python base.
@attached(member, names: prefixed(__p_), named(__p_identity))
@attached(memberAttribute)
@attached(
    extension,
    conformances: _PClass,
    names: named(_pIdentity)
)
public macro PythonExportedClass(
    _ name: String? = nil,
    module: (any ModuleHost.Type)? = nil,
    documentation: String? = nil,
) = #externalMacro(module: "PythonMacros", type: "PythonExportedClassMacro")

/// Binds a Swift struct to a class in an importable Python module.
///
/// The struct retains the Python instance. Its properties and methods, including
/// class methods, work inside `Session.enqueue` or a Swift export. Declare typed
/// members with `PythonProperty` and `PythonFunction`.
@attached(memberAttribute)
@attached(
    member,
    conformances: Encodable,
    Decodable,
    names: named(_pImport),
    named(__p_reference)
)
@attached(
    extension,
    conformances: _PImported,
    Encodable,
    Decodable,
    Sendable,
    names: named(init(from:)),
    named(encode(to:)),
    named(object(in:)),
    named(callAsFunction(_:))
)
public macro PythonImportedClass(
    module: String,
    name: String,
) = #externalMacro(module: "PythonMacros", type: "PythonImportedClassMacro")

/// Binds a function in the direction selected by its enclosing Python macro.
/// An exported function can receive a Context as its first unlabeled argument.
/// An imported function declares a throwing signature with no body. Unlabeled
/// arguments are positional and labels supply Python keywords. An async
/// signature awaits a Python result during an active Swift export.
@attached(peer, names: prefixed(__p_))
public macro PythonFunction(
    _ name: String? = nil,
    documentation: String? = nil,
) = #externalMacro(
    module: "PythonMacros",
    type: "PythonFunctionMacro",
)

/// Selects a synchronous, non-failable initializer. It may receive a `Context` parameter.
@attached(peer, names: prefixed(__p_))
public macro PythonInit(documentation: String? = nil) = #externalMacro(
    module: "PythonMacros",
    type: "PythonInitMacro",
)

/// Binds a property in the direction selected by its enclosing Python macro.
/// An imported property has a throwing getter and a dollar-prefixed method for Swift writes.
@attached(peer, names: prefixed(__p_), prefixed(`$`))
public macro PythonProperty(
    _ name: String? = nil,
    isReadOnly: Bool = false,
    documentation: String? = nil,
) = #externalMacro(module: "PythonMacros", type: "PythonPropertyMacro")

@_documentation(visibility: internal)
@attached(accessor, names: named(get))
public macro _PythonPropertyGetter() = #externalMacro(
    module: "PythonMacros",
    type: "PythonPropertyGetterMacro",
)

@_documentation(visibility: internal)
@attached(body)
public macro _PythonImportedFunction() = #externalMacro(
    module: "PythonMacros",
    type: "PythonFunctionMacro",
)

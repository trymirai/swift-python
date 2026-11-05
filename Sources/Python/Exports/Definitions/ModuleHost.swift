//
//  Created by Anton Spivak
//

/// A Swift type or configured instance exported by `PythonModule`.
public protocol ModuleHost: Sendable, SendableMetatype {
    @_documentation(visibility: internal)
    static var _pythonModuleName: String { get }

    @_documentation(visibility: internal)
    static var _pythonModuleDocumentation: String? { get }

    @_documentation(visibility: internal)
    static func _pythonDefaultInstance() throws -> (any ModuleHost)?
}

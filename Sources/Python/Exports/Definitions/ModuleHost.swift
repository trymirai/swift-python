//
//  Created by Anton Spivak
//

/// A Swift type exported by `PythonModule`.
public protocol ModuleHost: SendableMetatype {
    @_documentation(visibility: internal)
    static var _pModuleName: String { get }

    @_documentation(visibility: internal)
    static var _pModuleDocumentation: String? { get }
}

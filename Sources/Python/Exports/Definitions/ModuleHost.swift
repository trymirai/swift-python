//
//  Created by Anton Spivak
//

// MARK: - ModuleHost

/// A Swift type exported by `PythonExportedModule`.
public protocol ModuleHost: SendableMetatype {
    @_documentation(visibility: internal)
    static var _pModuleName: String { get }

    @_documentation(visibility: internal)
    static var _pModuleDocumentation: String? { get }

    @_documentation(visibility: internal)
    static var _pModuleSource: String? { get }
}

public extension ModuleHost {
    @_documentation(visibility: internal)
    static var _pModuleSource: String? {
        nil
    }
}

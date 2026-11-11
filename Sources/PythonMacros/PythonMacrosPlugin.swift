//
//  Created by Anton Spivak
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

// MARK: - PythonMacrosPlugin

@main
struct PythonMacrosPlugin {}

// MARK: CompilerPlugin

extension PythonMacrosPlugin: CompilerPlugin {
    var providingMacros: [Macro.Type] {
        [
            PythonExportedModuleMacro.self,
            PythonExportedClassMacro.self,
            PythonImportedClassMacro.self,

            PythonFunctionMacro.self,
            PythonInitMacro.self,
            PythonPropertyMacro.self,
            PythonPropertyGetterMacro.self,
        ]
    }
}

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
            PythonModuleMacro.self,
            PythonFunctionMacro.self,
            PythonClassMacro.self,
            PythonInitMacro.self,
            PythonPropertyMacro.self,
            PythonReferenceMacro.self,
        ]
    }
}

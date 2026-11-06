//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonFunctionMacro

struct PythonFunctionMacro {}

// MARK: PeerMacro

extension PythonFunctionMacro: PeerMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        let scope = ExportScope(context)
        try scope.validate()
        guard let method = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroExpansionErrorMessage(
                "PythonFunction must be attached to a function or method.",
            )
        }
        let isStatic = method.modifiers.declaresStaticMember

        guard
            let owner = scope.owner,
            owner.hasClassMacro || owner.isExtension || (isStatic && owner.isModule)
        else {
            throw MacroExpansionErrorMessage(
                "A Python module function must be static; instance methods require PythonClass.",
            )
        }
        if owner.hasClassMacro && isStatic {
            throw MacroExpansionErrorMessage(
                "Exported Python classes support instance methods only.",
            )
        }

        let function = try FunctionExpansion(declaration: method, owner: owner).source(
            attribute: attribute,
            isInstanceMethod: !isStatic,
        )
        let definition = isStatic
            ? "collector.addFunction(module: \(owner.name).self, function: \(function))"
            : "collector.addMethod(\(owner.name).self, function: \(function))"
        return [ExportRegistration(method: method, definition: definition, in: context).declaration]
    }
}

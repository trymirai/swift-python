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
        let owner = scope.owner
        let isStatic = method.modifiers.contains { ["static", "class"].contains($0.name.text) }
        if let owner, owner.isPythonClass || (owner.isExtension && !isStatic) {
            guard !isStatic
            else {
                throw MacroExpansionErrorMessage(
                    "Exported Python classes support instance methods only.",
                )
            }
            let function = try FunctionExpansion(declaration: method, owner: owner).source(
                attribute: attribute,
                isInstanceMethod: true,
            )
            return [ExportRegistration(
                method: method,
                definition: "collector.addMethod(\(owner.name).self, function: \(function))",
                in: context,
            ).declaration]
        }
        guard let owner, isStatic, owner.isModule || owner.isExtension else {
            throw MacroExpansionErrorMessage(
                "A Python module function must be static; instance methods require PythonClass.",
            )
        }
        let function = try FunctionExpansion(declaration: method, owner: owner)
            .source(attribute: attribute)
        return [ExportRegistration(
            method: method,
            definition: "collector.addFunction(module: \(owner.name).self, function: \(function))",
            in: context,
        ).declaration]
    }
}

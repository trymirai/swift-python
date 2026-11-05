//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonInitMacro

struct PythonInitMacro {}

// MARK: PeerMacro

extension PythonInitMacro: PeerMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        try ExportScope(context).validate()
        guard
            let initializer = declaration.as(InitializerDeclSyntax.self),
            let owner = ExportScope(context).owner,
            owner.isPythonClass || owner.isExtension
        else {
            throw MacroExpansionErrorMessage("PythonInit requires an initializer of a PythonClass.")
        }
        guard
            initializer.optionalMark == nil, initializer.genericParameterClause == nil,
            initializer.signature.effectSpecifiers?.asyncSpecifier == nil
        else {
            throw MacroExpansionErrorMessage(
                "PythonInit must be synchronous, non-generic and non-failable; throwing is supported.",
            )
        }
        var method = FunctionDeclSyntax(name: .identifier("init"), signature: initializer.signature)
        // The parsed initializer signature has no result clause; attach the concrete class result.
        method.signature
            .returnClause = ReturnClauseSyntax(type: TypeSyntax(stringLiteral: owner.name))
        let function = try FunctionExpansion(declaration: method).source(
            attribute: attribute,
            receiver: "\(owner.name).",
            owner: owner,
            kind: .initializer,
        )
        return [ExportRegistration(
            method: method,
            definition: "collector.addInitializer(\(owner.name).self, function: \(function))",
            in: context,
        ).declaration]
    }
}

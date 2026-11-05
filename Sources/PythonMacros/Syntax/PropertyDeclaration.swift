//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct PropertyDeclaration {
    let variable: VariableDeclSyntax
    let name: String
    let owner: ExportScope.Owner

    init(_ declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws {
        try ExportScope(context).validate()

        guard
            let variable = declaration.as(VariableDeclSyntax.self),
            variable.bindings.count == 1
        else {
            throw MacroExpansionErrorMessage(
                "Python properties require a single instance property of a PythonClass.",
            )
        }

        let name = variable.bindings
            .first?
            .pattern
            .as(IdentifierPatternSyntax.self)?
            .identifier
            .trimmedDescription

        guard
            let name,
            !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }),
            let owner = ExportScope(context).owner,
            owner.isPythonClass || owner.isExtension
        else {
            throw MacroExpansionErrorMessage(
                "Python properties require a single instance property of a PythonClass.",
            )
        }

        self.variable = variable
        self.name = name
        self.owner = owner
    }
}

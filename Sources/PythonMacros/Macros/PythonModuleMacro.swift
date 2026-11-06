//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonModuleMacro

struct PythonModuleMacro {}

// MARK: MemberMacro

extension PythonModuleMacro: MemberMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        try ExportScope(context).validate()

        guard let type = declaration.exportTypeDeclaration else {
            throw MacroExpansionErrorMessage(
                "PythonModule requires an enum, struct, actor or class.",
            )
        }

        guard type.genericParameterClause == nil else {
            throw MacroExpansionErrorMessage("PythonModule requires a concrete, non-generic type.")
        }

        guard let name = attribute.argument() else {
            throw MacroExpansionErrorMessage("PythonModule requires a module name.")
        }

        func metadata(_ member: String, type: String, value: String) -> DeclSyntax {
            DeclSyntax(
                stringLiteral:
                "@_documentation(visibility: internal) public nonisolated static var \(member): \(type) { \(value) }",
            )
        }

        return [
            metadata("_pModuleName", type: "Swift::String", value: name),
            metadata(
                "_pModuleDocumentation",
                type: "Swift::String?",
                value: attribute.documentationSource,
            ),
        ]
    }
}

// MARK: ExtensionMacro

extension PythonModuleMacro: ExtensionMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else {
            return []
        }
        return [try ExtensionDeclSyntax("extension \(type): Python::ModuleHost {}")]
    }
}

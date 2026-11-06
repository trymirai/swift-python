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

        guard
            declaration.is(StructDeclSyntax.self) || declaration.is(ClassDeclSyntax.self)
            || declaration.is(EnumDeclSyntax.self) || declaration.is(ActorDeclSyntax.self)
        else {
            throw MacroExpansionErrorMessage(
                "PythonModule requires an enum, struct, actor or class.",
            )
        }

        guard
            declaration.as(StructDeclSyntax.self)?.genericParameterClause == nil,
            declaration.as(ClassDeclSyntax.self)?.genericParameterClause == nil,
            declaration.as(EnumDeclSyntax.self)?.genericParameterClause == nil,
            declaration.as(ActorDeclSyntax.self)?.genericParameterClause == nil
        else {
            throw MacroExpansionErrorMessage("PythonModule requires a concrete, non-generic type.")
        }

        guard let name = attribute.argument() else {
            throw MacroExpansionErrorMessage("PythonModule requires a module name.")
        }

        let documentation = attribute.argument(named: "documentation") ?? "nil"

        return [
            DeclSyntax(
                stringLiteral: "@_documentation(visibility: internal) public nonisolated static var _pythonModuleName: Swift::String { \(name) }",
            ),
            DeclSyntax(
                stringLiteral: "@_documentation(visibility: internal) public nonisolated static var _pythonModuleDocumentation: Swift::String? { \(documentation) }",
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

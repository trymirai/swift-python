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
                "PythonModule requires an enum, struct, actor or Sendable class.",
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
        let owner = ExportScope(context).qualifiedName(of: declaration)

        let isNamespace = declaration.is(EnumDeclSyntax.self)
        let isMainActorIsolated = declaration.attributes.attribute(named: "MainActor") != nil

        let initializers = declaration.memberBlock
            .members
            .compactMap { $0.decl.as(InitializerDeclSyntax.self) }

        let hasUninitializedProperties = declaration.memberBlock
            .members
            .compactMap { $0.decl.as(VariableDeclSyntax.self) }
            .filter { !$0.modifiers.contains { ["static", "class"].contains($0.name.text) } }
            .contains { $0.bindings.contains { $0.initializer == nil && $0.accessorBlock == nil } }

        let defaultInitializer = initializers.first {
            $0.optionalMark == nil
                && $0.signature.effectSpecifiers?.asyncSpecifier == nil
                && $0.signature.parameterClause.parameters.allSatisfy { $0.defaultValue != nil }
        }

        let hasDefaultInitializer = initializers.isEmpty
            ? !hasUninitializedProperties
            : defaultInitializer != nil

        let initializerPrefix = defaultInitializer?.signature.effectSpecifiers?.throwsClause == nil
            ? ""
            : "try "

        let defaultInstance: String = if isNamespace {
            "return nil"
        } else if hasDefaultInitializer && !isMainActorIsolated {
            "return \(initializerPrefix)\(owner)()"
        } else {
            "throw Python::Exception(name: \"TypeError\", message: \"This module requires moduleInstances with an explicit configuration.\")"
        }

        return [
            DeclSyntax(
                stringLiteral: "@_documentation(visibility: internal) public nonisolated static var _pythonModuleName: Swift::String { \(name) }",
            ),
            DeclSyntax(
                stringLiteral: "@_documentation(visibility: internal) public nonisolated static var _pythonModuleDocumentation: Swift::String? { \(documentation) }",
            ),
            DeclSyntax(
                stringLiteral: "@_documentation(visibility: internal) public nonisolated static func _pythonDefaultInstance() throws -> (any Python::ModuleHost)? { \(defaultInstance) }",
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
        let result = DeclSyntax(
            stringLiteral: "extension \(type.trimmedDescription): Python::ModuleHost {}",
        )
        return result.as(ExtensionDeclSyntax.self).map { [$0] } ?? []
    }
}

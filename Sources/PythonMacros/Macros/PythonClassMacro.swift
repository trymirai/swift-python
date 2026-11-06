//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonClassMacro

struct PythonClassMacro {}

// MARK: MemberMacro

extension PythonClassMacro: MemberMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        let scope = ExportScope(context)
        try scope.validate()
        guard
            let declaration = declaration.as(ClassDeclSyntax.self),
            declaration.genericParameterClause == nil
        else {
            throw MacroExpansionErrorMessage("PythonClass requires a concrete Swift class.")
        }

        guard declaration.attributes.attribute(named: "MainActor") == nil else {
            throw MacroExpansionErrorMessage(
                "An exported Swift class runs on the session thread and cannot be MainActor-isolated.",
            )
        }

        let owner = scope.qualifiedName(of: declaration)
        let name = attribute.argument() ?? String(reflecting: declaration.name.text)

        let module = attribute.argument(named: "module")
            ?? scope.owner.flatMap { $0.isModule ? "\($0.name).self" : nil }

        guard let module else {
            throw MacroExpansionErrorMessage(
                "PythonClass requires module: Module.self or a surrounding PythonModule.",
            )
        }

        let documentation = attribute.argument(named: "documentation") ?? "nil"
        let initializers = declaration.memberBlock.members.count {
            $0.decl.as(InitializerDeclSyntax.self)?.attributes.attribute(named: "PythonInit") != nil
        }
        guard initializers <= 1 else {
            throw MacroExpansionErrorMessage("Select at most one PythonInit per concrete class.")
        }

        let registration = ExportRegistration(
            name: "class",
            definition:
            "collector.addClass(\(owner).self, module: \(module), name: \(name), documentation: \(documentation))",
            in: context,
        ).declaration

        let identity: DeclSyntax = """
        private nonisolated let __python_identity: (any Swift::AnyObject & Swift::Sendable)? =
            Python::_makeInstanceIdentity(for: \(raw: owner).self)
        """
        return [registration, identity]
    }
}

// MARK: MemberAttributeMacro

extension PythonClassMacro: MemberAttributeMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [AttributeSyntax] {
        guard
            let variable = member.as(VariableDeclSyntax.self),
            variable.attributes.attribute(named: "PythonProperty") != nil,
            PropertyDeclaration.usesPythonStorage(variable)
        else {
            return []
        }
        return [AttributeSyntax(stringLiteral: "@Python::_PythonStoredProperty")]
    }
}

// MARK: ExtensionMacro

extension PythonClassMacro: ExtensionMacro {
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
        return [try ExtensionDeclSyntax("""
        extension \(type): Python::_PythonClass {
            public nonisolated var _pythonIdentity: any Swift::AnyObject & Swift::Sendable { __python_identity! }
            public nonisolated var _pythonContext: Python::Context { self.context }
        }
        """)]
    }
}

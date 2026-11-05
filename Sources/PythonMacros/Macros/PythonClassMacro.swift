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
        try ExportScope(context).validate()
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

        let owner = ExportScope(context).qualifiedName(of: declaration)
        let name = attribute
            .argument()
            .flatMap { $0 == "nil" ? nil : $0 } ?? String(reflecting: declaration.name.text)

        let module = attribute.argument(named: "module").flatMap { $0 == "nil" ? nil : $0 }
            ?? ExportScope(context).owner.flatMap { $0.isModule ? "\($0.name).self" : nil }

        guard let module else {
            throw MacroExpansionErrorMessage(
                "PythonClass requires module: Module.self or a surrounding PythonModule.",
            )
        }

        let documentation = attribute.argument(named: "documentation") ?? "nil"
        let initializers = declaration.memberBlock
            .members
            .compactMap { $0.decl.as(InitializerDeclSyntax.self) }
            .filter { $0.attributes.attribute(named: "PythonInit") != nil }

        guard initializers.count <= 1
        else {
            throw MacroExpansionErrorMessage("Select at most one PythonInit per concrete class.")
        }

        var result: [DeclSyntax] = [ExportRegistration(
            name: "class",
            definition:
            "collector.addClass(\(owner).self, module: \(module), name: \(name), documentation: \(documentation))",
            in: context,
        ).declaration]

        result.append(DeclSyntax(
            stringLiteral: "private nonisolated let __python_identity: (any Swift::AnyObject & Swift::Sendable)? = Python::Module._makeInstanceIdentity(for: \(owner).self)",
        ))
        return result
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
        }
        """)]
    }
}

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
        try ExportScope(context).validate()
        guard let method = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroExpansionErrorMessage(
                "PythonFunction must be attached to a function or method.",
            )
        }
        let owner = ExportScope(context).owner
        let isStatic = method.modifiers.contains { ["static", "class"].contains($0.name.text) }
        if let owner, owner.isPythonClass || (owner.isExtension && !isStatic) {
            guard !isStatic
            else {
                throw MacroExpansionErrorMessage(
                    "Exported Python classes support instance methods only.",
                )
            }
            let function = try FunctionExpansion(declaration: method).source(
                attribute: attribute,
                receiver: "__self.",
                owner: owner,
                kind: .instanceMethod,
            )
            return [ExportRegistration(
                method: method,
                definition: "collector.addMethod(\(owner.name).self, function: \(function))",
                in: context,
            ).declaration]
        }
        let module = attribute.argument(named: "module").flatMap { $0 == "nil" ? nil : $0 }
            ?? owner
            .flatMap { ($0.isModule || ($0.isExtension && isStatic)) ? "\($0.name).self" : nil }
        guard let module else {
            throw MacroExpansionErrorMessage(
                "A free Python function requires module: Module.self; instance methods require PythonClass.",
            )
        }
        let requiresModuleInstance = owner != nil && !isStatic
        let receiver = owner.map { isStatic ? "\($0.name)." : "__instance." } ?? ""
        let definition = try FunctionExpansion(declaration: method).source(
            attribute: attribute,
            receiver: receiver,
            owner: owner,
        )
        var unwrap = ""
        if requiresModuleInstance, let owner {
            unwrap = """
            guard let __instance = __instance as? \(owner.name) else {
                throw Python::Exception(name: "TypeError", message: "Missing configured module instance.")
            }
            """
        }
        let export = """
        collector.addFunction(module: \(module), makeFunction: { \(requiresModuleInstance ? "__instance" : "_") in
            \(unwrap)
            return \(definition)
        })
        """
        return [ExportRegistration(method: method, definition: export, in: context).declaration]
    }
}

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
        let scope = ExportScope(context)
        try scope.validate()

        guard
            let initializer = declaration.as(InitializerDeclSyntax.self),
            let owner = scope.owner,
            owner.isImportedClass || owner.isExportedClass || owner.isExtension
        else {
            throw MacroExpansionErrorMessage(
                "PythonInit requires an initializer of a PythonImportedClass or PythonExportedClass.",
            )
        }

        if owner.isImportedClass {
            return []
        }

        guard
            initializer.optionalMark == nil, initializer.genericParameterClause == nil,
            initializer.signature.effectSpecifiers?.asyncSpecifier == nil
        else {
            throw MacroExpansionErrorMessage(
                "PythonInit must be synchronous, non-generic and non-failable; throwing is supported.",
            )
        }

        // Model the initializer as a function returning an instance for the export binder.
        var method = FunctionDeclSyntax(name: .identifier("init"), signature: initializer.signature)
        method.signature
            .returnClause = ReturnClauseSyntax(type: TypeSyntax(stringLiteral: owner.name))
        let function = try FunctionExpansion(declaration: method, owner: owner)
            .source(attribute: attribute)
        return [ExportRegistration(
            method: method,
            definition: "collector.addInitializer(\(owner.name).self, function: \(function))",
            in: context,
        ).declaration]
    }
}

extension PythonInitMacro {
    static func importedBody(for initializer: InitializerDeclSyntax) throws -> CodeBlockItemSyntax {
        guard
            initializer.body == nil, initializer.optionalMark == nil,
            let effects = initializer.signature.effectSpecifiers, effects.throwsClause != nil
        else {
            throw MacroExpansionErrorMessage(
                "Declare an imported PythonInit as a non-failable throwing initializer with no body.",
            )
        }

        let parameters = initializer.signature.parameterClause.parameters
        let isAsync = effects.asyncSpecifier != nil

        guard
            let target = parameters.last, target.firstName.text == "in",
            let localName = target.secondName, localName.text != "_", target.ellipsis == nil
        else {
            let destination = isAsync ? "in session: Session" : "in context: Context"
            throw MacroExpansionErrorMessage("End the imported PythonInit with '\(destination)'.")
        }

        let arguments = try importedArguments(for: parameters.dropLast())
        let targetLabel = isAsync ? "inSession" : "inContext"
        let invocation = isAsync ? "try await" : "try"

        return CodeBlockItemSyntax(stringLiteral: """
        self = \(invocation) Self._pConstruct(\(targetLabel): \(localName.trimmedDescription), \(arguments))
        """)
    }
}

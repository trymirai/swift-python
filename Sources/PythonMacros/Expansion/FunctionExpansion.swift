//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct FunctionExpansion {
    let declaration: FunctionDeclSyntax
    let owner: ExportScope.Owner

    func source(
        attribute: AttributeSyntax,
        isInstanceMethod: Bool = false,
    ) throws -> String {
        guard declaration.genericParameterClause == nil else {
            throw MacroExpansionErrorMessage(
                "Python functions require concrete Swift parameter types.",
            )
        }

        let isMutatingOrConsuming = declaration
            .modifiers
            .contains(where: { ["mutating", "consuming"].contains($0.name.text) })

        if isMutatingOrConsuming {
            throw MacroExpansionErrorMessage("Exported methods must keep their receiver available.")
        }

        let name = attribute.argument() ?? String(reflecting: declaration.name.text)
        let documentation = attribute.argument(named: "documentation") ?? "nil"

        let isStatic = declaration.modifiers.contains { ["static", "class"].contains($0.name.text) }
        let isIsolated = !declaration.modifiers.contains { $0.name.text == "nonisolated" }
            && ((owner.isActor && !isStatic) || owner.isMainActorIsolated)

        let signature = declaration.signature
        let isAsynchronous = signature.effectSpecifiers?.asyncSpecifier != nil
            || isIsolated
            || declaration.attributes.attribute(named: "MainActor") != nil

        let isThrowing = signature.effectSpecifiers?.throwsClause != nil
        let parameters = try signature
            .parameterClause
            .parameters
            .enumerated()
            .map { index, parameter in
                try ParameterExpansion(
                    parameter,
                    index: index,
                    owner: owner.name,
                    hasReceiver: isInstanceMethod,
                )
            }

        let metadata = (isInstanceMethod ? [".receiver"] : []) + parameters.map(\.metadataSource)
        let arguments = parameters.map(\.argumentSource).joined(separator: ", ")
        let returnType = signature
            .returnClause
            .map { $0.type.concreteSpelling(owner: owner.name) } ?? "Swift::Void"

        let prefix = (isThrowing ? "try " : "") + (isAsynchronous ? "await " : "")
        let receiver = isInstanceMethod ? "__self" : owner.name
        let invocation = "\(prefix)\(receiver).\(declaration.name.trimmedDescription)(\(arguments))"
        let receiverBinding = isInstanceMethod
            ? "let __self = try arguments.receiver(as: \(owner.name).self)"
            : ""
        let body = callBody(
            invoking: invocation,
            returning: returnType,
            receiverBinding: receiverBinding,
            parameters: parameters,
            isAsynchronous: isAsynchronous,
        )
        return """
        Python::_ExportFunction(
            \(name), documentation: \(documentation),
            parameters: [\(metadata.joined(separator: ", "))],
            returning: (\(returnType)).self, \(body))
        """
    }

    private func callBody(
        invoking invocation: String,
        returning returnType: String,
        receiverBinding: String,
        parameters: [ParameterExpansion],
        isAsynchronous: Bool,
    ) -> String {
        var expression: String = if isAsynchronous {
            """
            return Python::_ExportFunction.makeOperation {
                let result: \(returnType) = \(invocation)
                return result
            }
            """
        } else {
            "return \(invocation)"
        }

        for parameter in parameters.reversed() {
            expression = parameter.wrapping(expression, isAsynchronous: isAsynchronous)
        }

        if isAsynchronous {
            return """
            start: { arguments, _ in
                \(receiverBinding)
                \(expression)
            }
            """
        }

        // Validate every argument before any borrowed buffer is opened.
        let preparation = parameters.map(\.preparationSource).joined(separator: "\n")
        return """
        call: { arguments, _, encoder in
            let result: \(returnType) = try { () throws -> \(returnType) in
                \(receiverBinding)
                \(preparation)
                \(expression)
            }()
            try encoder.encode(result)
        }
        """
    }
}

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
        try validateSignature()

        let name = attribute.nameSource(default: declaration.name.text)
        let documentation = attribute.documentationSource
        let isAsynchronous = requiresAwait

        let signature = declaration.signature
        let isThrowing = signature.effectSpecifiers?.throwsClause != nil
        let returnType = signature
            .returnClause
            .map { $0.type.concreteSpelling(owner: owner.name) } ?? "Swift::Void"
        let parameters = try expandParameters(hasReceiver: isInstanceMethod)
        let metadata = (isInstanceMethod ? [".receiver"] : []) + parameters.map(\.metadataSource)

        let arguments = parameters.map(\.argumentSource).joined(separator: ", ")
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

    private func validateSignature() throws {
        guard declaration.genericParameterClause == nil else {
            throw MacroExpansionErrorMessage(
                "Python functions require concrete Swift parameter types.",
            )
        }

        let changesReceiver = declaration.modifiers.contains {
            $0.name.text == "mutating" || $0.name.text == "consuming"
        }
        if changesReceiver {
            throw MacroExpansionErrorMessage("Exported methods must keep their receiver available.")
        }
    }

    private var requiresAwait: Bool {
        let modifiers = declaration.modifiers
        let isInstanceActorMethod = owner.isActor && !modifiers.declaresStaticMember
        let isNonisolated = modifiers.contains { $0.name.text == "nonisolated" }
        let isIsolated = !isNonisolated && (isInstanceActorMethod || owner.isMainActorIsolated)

        return declaration.signature.effectSpecifiers?.asyncSpecifier != nil
            || isIsolated
            || declaration.attributes.attribute(named: "MainActor") != nil
    }

    private func expandParameters(hasReceiver: Bool) throws -> [ParameterExpansion] {
        try declaration.signature.parameterClause.parameters.enumerated().map { index, parameter in
            try ParameterExpansion(
                parameter,
                index: index,
                owner: owner.name,
                hasReceiver: hasReceiver,
            )
        }
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

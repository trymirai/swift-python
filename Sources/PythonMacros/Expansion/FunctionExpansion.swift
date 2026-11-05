//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct FunctionExpansion {
    let declaration: FunctionDeclSyntax

    enum Kind {
        case module
        case instanceMethod
        case initializer
    }

    func source(
        attribute: AttributeSyntax,
        receiver: String,
        owner: ExportScope.Owner? = nil,
        kind: Kind = .module,
    ) throws -> String {
        let isInstanceMethod = kind == .instanceMethod
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

        let name = attribute
            .argument()
            .flatMap { $0 == "nil" ? nil : $0 } ?? String(reflecting: declaration.name.text)

        let documentation = attribute.argument(named: "documentation") ?? "nil"

        let isStatic = declaration.modifiers.contains { ["static", "class"].contains($0.name.text) }
        let isIsolated = !declaration.modifiers.contains { $0.name.text == "nonisolated" }
            && ((owner?.isActor == true && !isStatic) || owner?.isMainActorIsolated == true)

        let isAsynchronous = declaration.signature.effectSpecifiers?.asyncSpecifier != nil
            || isIsolated
            || declaration.attributes.attribute(named: "MainActor") != nil

        if isInstanceMethod && isAsynchronous {
            throw MacroExpansionErrorMessage(
                "Exported instance methods must be synchronous; use an async module function for Sendable values.",
            )
        }

        let isThrowing = declaration.signature.effectSpecifiers?.throwsClause != nil
        let parameterExpansions = try declaration.signature
            .parameterClause
            .parameters
            .enumerated()
            .map { index, parameter in
                try ParameterExpansion(
                    parameter,
                    index: index,
                    owner: owner?.name,
                    hasReceiver: isInstanceMethod,
                )
            }

        let parameters = (isInstanceMethod ? [".init(\"self\")"] : [])
            + parameterExpansions.map(\.metadataSource)

        let arguments = parameterExpansions.map(\.argumentSource)
        let returnType = declaration.signature
            .returnClause
            .map { $0.type.concreteSpelling(owner: owner?.name) } ?? "Swift::Void"

        let prefix = (isThrowing ? "try " : "") + (isAsynchronous ? "await " : "")
        let invocation = "\(prefix)\(receiver)\(declaration.name.trimmedDescription)(\(arguments.joined(separator: ", ")))"
        var expression: String = if isAsynchronous {
            """
            return Python::Module.Function.makeOperation {
                let result: \(returnType) = \(invocation)
                return result
            }
            """
        } else {
            "return \(invocation)"
        }

        for parameter in parameterExpansions.reversed() {
            expression = parameter.wrapping(expression, isAsynchronous: isAsynchronous)
        }

        let body: String
        if isAsynchronous {
            body = """
            start: { arguments, _ in
                \(expression)
            }
            """
        } else {
            let receiverLine = if isInstanceMethod {
                "let __self = try arguments.receiver(as: \(owner?.name ?? "Self").self)"
            } else {
                ""
            }

            let preparationSource = parameterExpansions
                .map(\.preparationSource)
                .joined(separator: "\n")

            body = """
            call: { arguments, context, encoder in
                let result: \(returnType) = try { () throws -> \(returnType) in
                    \(receiverLine)
                    \(preparationSource)
                    \(expression)
                }()
                try encoder.\(kind == .initializer ? "_encodeNewInstance" : "encode")(result)
            }
            """
        }

        return """
        Python::Module.Function(\(name), documentation: \(documentation), parameters: [\(parameters.joined(separator: ", "))],
            returning: (\(returnType)).self, \(body))
        """
    }
}

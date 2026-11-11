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
        let scope = ExportScope(context)
        try scope.validate()

        guard let method = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroExpansionErrorMessage(
                "PythonFunction must be attached to a function or method.",
            )
        }

        let owner = scope.owner
        if owner?.isImportedClass == true {
            return []
        }

        let isStatic = method.modifiers.declaresStaticMember
        guard
            let owner,
            owner.isExportedClass || owner.isExtension || (isStatic && owner.isModule)
        else {
            throw MacroExpansionErrorMessage(
                "A Python module function must be static; instance methods require PythonExportedClass.",
            )
        }
        if owner.isExportedClass && isStatic {
            throw MacroExpansionErrorMessage(
                "Exported Python classes support instance methods only.",
            )
        }

        let function = try FunctionExpansion(declaration: method, owner: owner).source(
            attribute: attribute,
            isInstanceMethod: !isStatic,
        )
        let definition = isStatic
            ? "collector.addFunction(module: \(owner.name).self, function: \(function))"
            : "collector.addMethod(\(owner.name).self, function: \(function))"

        return [ExportRegistration(method: method, definition: definition, in: context).declaration]
    }
}

// MARK: BodyMacro

extension PythonFunctionMacro: BodyMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext,
    ) throws -> [CodeBlockItemSyntax] {
        guard
            let method = declaration.as(FunctionDeclSyntax.self),
            method.body == nil,
            let annotation = method.attributes.attribute(named: "PythonFunction"),
            let effects = method.signature.effectSpecifiers,
            effects.throwsClause != nil
        else {
            throw MacroExpansionErrorMessage(
                "Declare an imported PythonFunction as a throwing signature with no body.",
            )
        }

        let arguments = try argumentsSource(for: method.signature.parameterClause.parameters)
        let name = annotation.nameSource(default: method.name.identifier?.name ?? method.name.text)
        let type = method.signature.returnClause?.type.trimmedDescription ?? "Swift::Void"

        func forwardingBody(_ call: String) -> CodeBlockItemSyntax {
            CodeBlockItemSyntax(stringLiteral: """
            return \(call)(\(name), \(arguments)) {
                try $0.decode(as: (\(type)).self)
            }
            """)
        }

        func synchronousBody() -> CodeBlockItemSyntax {
            if method.modifiers.declaresStaticMember {
                return forwardingBody("try Self._pCallMethod")
            }
            return CodeBlockItemSyntax(stringLiteral: """
            return try self { object in
                let method = try object.attribute(\(name))
                return try method.call(\(arguments)).decode(as: (\(type)).self)
            }
            """)
        }

        if effects.asyncSpecifier != nil {
            let receiver = method.modifiers.declaresStaticMember ? "Self" : "self.__p_reference"
            return [forwardingBody("try await \(receiver)._pAwaitMethod")]
        }
        return [synchronousBody()]
    }

    private static func argumentsSource(for parameters: FunctionParameterListSyntax) throws
        -> String
    {
        var positional = [String]()
        var keywords = [String]()

        for parameter in parameters {
            let localName = parameter.secondName ?? parameter.firstName
            guard
                localName.text != "_", parameter.ellipsis == nil,
                !parameter.type.trimmedDescription.hasPrefix("inout ")
            else {
                throw MacroExpansionErrorMessage(
                    "Imported Python parameters require names and fixed, encodable types.",
                )
            }

            if parameter.firstName.text == "_" {
                positional.append(localName.trimmedDescription)
            } else {
                let keyword = parameter.firstName.identifier?.name ?? parameter.firstName.text
                keywords.append("(\(String(reflecting: keyword)), \(localName.trimmedDescription))")
            }
        }

        let positionalList = positional.joined(separator: ", ")
        let keywordList = keywords.joined(separator: ", ")
        return "arguments: [\(positionalList)], keywords: [\(keywordList)]"
    }
}

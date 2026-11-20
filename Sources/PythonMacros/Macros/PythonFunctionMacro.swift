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
            return try sessionOverload(for: method, annotation: attribute)
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
        let definition = if isStatic {
            "collector.addFunction(module: \(owner.name).self, function: \(function))"
        } else {
            "collector.addMethod(\(owner.name).self, function: \(function))"
        }

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
        if let initializer = declaration.as(InitializerDeclSyntax.self) {
            return [try PythonInitMacro.importedBody(for: initializer)]
        }

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

        return [try importedBody(for: method, annotation: annotation)]
    }
}

private extension PythonFunctionMacro {
    static func sessionOverload(
        for method: FunctionDeclSyntax,
        annotation: AttributeSyntax,
    ) throws -> [DeclSyntax] {
        guard
            method.modifiers.declaresStaticMember,
            method.signature.effectSpecifiers?.asyncSpecifier != nil
        else {
            return []
        }

        var overload = method
        let bindingAttributes = ["PythonFunction", "_PythonImportedFunction"].compactMap { name in
            method.attributes.attribute(named: name)?.id
        }
        overload.attributes = method.attributes.filter { !bindingAttributes.contains($0.id) }

        var parameters = overload.signature.parameterClause.parameters
        let existingLocals = parameters.map { $0.secondName ?? $0.firstName }
        var localNames = Set(existingLocals.map { $0.identifier?.name ?? $0.text })

        func append(_ parameter: FunctionParameterSyntax) -> String {
            let name = (parameter.secondName ?? parameter.firstName).text
            var local = name
            while !localNames.insert(local).inserted {
                local += "_"
            }

            if !parameters.isEmpty {
                let last = parameters.index(before: parameters.endIndex)
                parameters[last].trailingComma = .commaToken()
            }

            var parameter = parameter
            // Preserve the overload's argument label when disambiguating the local name.
            if local != name {
                parameter.secondName = .identifier(local)
            }
            parameters.append(parameter)
            return local
        }

        let session = append("in session: Python::Session")
        let parent = append("from parent: Python::Context? = nil")
        let scope = append("scope: (any Swift::Sendable)? = nil")
        overload.signature.parameterClause.parameters = parameters

        let destination = ", in: \(session), from: \(parent), scope: \(scope)"
        let body = try importedBody(for: method, annotation: annotation, destination: destination)
        overload.body = CodeBlockSyntax { body }
        return [DeclSyntax(overload)]
    }

    static func importedBody(
        for method: FunctionDeclSyntax,
        annotation: AttributeSyntax,
        destination: String = "",
    ) throws -> CodeBlockItemSyntax {
        let arguments = try importedArguments(for: method.signature.parameterClause.parameters)
        let name = annotation.nameSource(default: method.name.identifier?.name ?? method.name.text)
        let type = method.signature.returnClause?.type.trimmedDescription ?? "Swift::Void"
        let isStatic = method.modifiers.declaresStaticMember

        let call: String
        if method.signature.effectSpecifiers?.asyncSpecifier != nil {
            let receiver = isStatic ? "Self" : "self.__p_reference"
            call = "try await \(receiver)._pAwaitMethod(\(name), \(arguments)\(destination))"
        } else if isStatic {
            call = "try Self._pCallMethod(\(name), \(arguments))"
        } else {
            return CodeBlockItemSyntax(stringLiteral: """
            return try self {
                try $0(methodNamed: \(name))(\(arguments)).decode(as: (\(type)).self)
            }
            """)
        }

        return CodeBlockItemSyntax(stringLiteral: """
        return \(call) {
            try $0.decode(as: (\(type)).self)
        }
        """)
    }
}

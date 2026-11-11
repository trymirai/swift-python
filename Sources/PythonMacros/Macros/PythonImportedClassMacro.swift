//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonImportedClassMacro

struct PythonImportedClassMacro {}

// MARK: MemberMacro

extension PythonImportedClassMacro: MemberMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        guard
            let declaration = declaration.as(StructDeclSyntax.self),
            declaration.genericParameterClause == nil
        else {
            throw MacroExpansionErrorMessage(
                "PythonImportedClass requires a concrete Swift struct.",
            )
        }

        guard
            let module = attribute.argument(named: "module"),
            let name = attribute.argument(named: "name")
        else {
            throw MacroExpansionErrorMessage(
                "PythonImportedClass requires a module and class name.",
            )
        }

        var members: [DeclSyntax] = [
            """
            public static let _pImport: (module: Swift::String, name: Swift::String) =
                (\(raw: module), \(raw: name))
            """,
        ]

        if try usesReference(protocols.map(protocolName)) {
            members.append("private let __p_reference: Python::Reference")
        }

        return members
    }
}

// MARK: MemberAttributeMacro

extension PythonImportedClassMacro: MemberAttributeMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [AttributeSyntax] {
        if
            let property = member.as(VariableDeclSyntax.self),
            property.attributes.attribute(named: "PythonProperty") != nil
        {
            return [AttributeSyntax(stringLiteral: "@Python::_PythonPropertyGetter")]
        }

        if
            let method = member.as(FunctionDeclSyntax.self),
            method.attributes.attribute(named: "PythonFunction") != nil
        {
            return [AttributeSyntax(stringLiteral: "@Python::_PythonImportedFunction")]
        }

        return []
    }
}

// MARK: ExtensionMacro

extension PythonImportedClassMacro: ExtensionMacro {
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

        let names = protocols.map(protocolName)
        let conformances = names.map { name in
            name == "Sendable" ? "Swift::Sendable" : "Python::\(name)"
        }
        .joined(separator: ", ")
        let codec = try usesReference(names) ? referenceCodec : ""

        return [try ExtensionDeclSyntax("""
        extension \(type): \(raw: conformances) {
            \(raw: codec)
        }
        """)]
    }
}

private extension PythonImportedClassMacro {
    static let referenceCodec = """
    public init(from decoder: borrowing Python::Decoder) throws {
        __p_reference = try Self._pDecodeReference(from: decoder)
    }

    public borrowing func encode(to encoder: inout Python::Encoder) throws {
        try encoder.encode(__p_reference)
    }

    public borrowing func callAsFunction<Result: ~Copyable>(
        _ body: (borrowing Python::Object) throws -> Result,
    ) throws -> Result {
        try __p_reference(body)
    }

    @_lifetime(borrow context)
    public borrowing func object(in context: borrowing Python::Context) throws -> Python::Object {
        try context.object(__p_reference)
    }
    """

    static func protocolName(_ type: TypeSyntax) -> String {
        type.as(MemberTypeSyntax.self)?.name.text ?? type.trimmedDescription
    }

    static func usesReference(_ names: [String]) throws -> Bool {
        let encode = names.contains("Encodable")
        let decode = names.contains("Decodable")
        guard encode == decode else {
            throw MacroExpansionErrorMessage(
                "Declare both Python coding conformances for a custom codec.",
            )
        }

        return encode
    }
}

//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonPropertyMacro

struct PythonPropertyMacro: PeerMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        let property = try PropertyDeclaration(declaration, in: context)

        if property.owner.isImportedClass {
            return try importedPeers(of: property, attribute: attribute)
        }
        if PropertyDeclaration.usesPStorage(property.variable) {
            return try storedPeers(of: property, attribute: attribute, in: context)
        }
        return try projectedPeers(of: property, attribute: attribute, in: context)
    }

    private static func importedPeers(
        of property: PropertyDeclaration,
        attribute: AttributeSyntax,
    ) throws -> [DeclSyntax] {
        let type = try property.importedTypeSource()
        switch attribute.argument(named: "isReadOnly") {
        case "true":
            return []
        case "false", nil:
            break
        default:
            throw MacroExpansionErrorMessage(
                "Use a boolean literal for an imported property's isReadOnly.",
            )
        }

        let name = property.pythonNameSource
        return writeMethods(
            for: property,
            type: type,
            setterBody: "try \(property.receiver) { try $0.setAttribute(\(name), to: newValue) }",
        )
    }

    private static func projectedPeers(
        of property: PropertyDeclaration,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        let name = property.pythonNameSource
        let documentation = attribute.documentationSource

        let setter = try projectedSetter(
            for: property,
            isReadOnly: attribute.argument(named: "isReadOnly") == "true",
        )

        let annotation = property.projectedAnnotationSource
        let definition = """
        collector.addProperty(
            \(property.owner.name).self, name: \(name), documentation: \(documentation),
            annotation: \(annotation),
            getter: { instance, _, encoder in try encoder.encode(instance.\(property.swiftSpelling)) },
            setter: \(setter))
        """
        let registration = ExportRegistration(
            name: property.name,
            definition: definition,
            in: context,
        )
        return [registration.declaration]
    }

    private static func projectedSetter(
        for property: PropertyDeclaration,
        isReadOnly: Bool,
    ) throws -> String {
        guard case let .accessors(accessors) = property.binding.accessorBlock?.accessors else {
            return "nil"
        }

        if accessors.contains(where: { $0.effectSpecifiers?.asyncSpecifier != nil }) {
            throw MacroExpansionErrorMessage("Python properties must have synchronous accessors.")
        }

        let hasPrivateSetter = property.variable.modifiers.contains {
            $0.detail?.detail.text == "set"
                && ["private", "fileprivate"].contains($0.name.text)
        }
        let hasWriteAccessor = accessors.contains {
            ["set", "willSet", "didSet", "_modify"].contains($0.accessorSpecifier.text)
        }
        guard
            property.variable.bindingSpecifier.text != "let",
            !isReadOnly, !hasPrivateSetter, hasWriteAccessor
        else {
            return "nil"
        }

        return "{ instance, decoder, _ in instance.\(property.swiftSpelling) = try decoder.decode() }"
    }

    private static func storedPeers(
        of property: PropertyDeclaration,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        guard !property.owner.isExtension else {
            throw MacroExpansionErrorMessage("Declare Python-stored properties in the class body.")
        }

        let (type, field) = try property.storageSource()
        let writeMethods = writeMethods(
            for: property,
            type: type,
            setterBody: "try self._pSetProperty(newValue, for: \(field))",
        )
        if property.access == "private" || property.access == "fileprivate" {
            return writeMethods
        }

        let name = property.pythonNameSource
        let documentation = attribute.documentationSource
        let readOnly = attribute.argument(named: "isReadOnly") ?? "false"

        let definition = """
        collector.addStoredProperty(\(property.owner.name).self, name: \(name), property: \(field),
            documentation: \(documentation), annotation: .init((\(type)).self), isReadOnly: \(readOnly))
        """
        let registration = ExportRegistration(
            name: property.name,
            definition: definition,
            in: context,
        )
        return writeMethods + [registration.declaration]
    }

    private static func writeMethods(
        for property: PropertyDeclaration,
        type: String,
        setterBody: String,
    ) -> [DeclSyntax] {
        let accessPrefix = property.access.map { $0 + " " } ?? ""
        let prefix = accessPrefix +
            (property.variable.modifiers.declaresStaticMember ? "static " : "")
        let setterName = property.swiftSetterName

        let setter = DeclSyntax(stringLiteral: """
        \(prefix)func \(setterName)(_ newValue: borrowing \(type)) throws {
            \(setterBody)
        }
        """)

        let updater = DeclSyntax(stringLiteral: """
        \(prefix)func \(setterName)(_ transform: (\(type)) throws -> \(type)) throws {
            let current = try self.\(property.swiftSpelling)
            let newValue = try transform(current)
            try self.\(setterName)(newValue)
        }
        """)

        return [setter, updater]
    }
}

// MARK: - PythonPropertyGetterMacro

struct PythonPropertyGetterMacro: AccessorMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [AccessorDeclSyntax] {
        let property = try PropertyDeclaration(declaration, in: context)

        let body: String
        if property.owner.isImportedClass {
            _ = try property.importedTypeSource()
            let name = property.pythonNameSource
            body = "try \(property.receiver) { try $0.attribute(\(name)).decode() }"
        } else {
            let field = try property.storageSource().field
            body = "try self._pGetProperty(\(field))"
        }

        return [AccessorDeclSyntax(stringLiteral: """
        get throws {
            \(body)
        }
        """)]
    }
}

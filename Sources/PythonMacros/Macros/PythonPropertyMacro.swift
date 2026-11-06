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
        if PropertyDeclaration.usesPStorage(property.variable) {
            return try storedPeers(of: property, attribute: attribute, in: context)
        }

        let pName = attribute.nameSource(default: property.name)
        let documentation = attribute.documentationSource

        let setter = try projectedSetter(
            for: property,
            isReadOnly: attribute.argument(named: "isReadOnly") == "true",
        )

        let definition = """
        collector.addProperty(\(property.owner.name).self, name: \(pName), documentation: \(documentation),
            getter: { instance, _, encoder in try encoder.encode(instance.\(property.swiftSpelling)) }, setter: \(setter))
        """
        return [ExportRegistration(name: property.name, definition: definition, in: context)
            .declaration]
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
        let canWrite = accessors.contains {
            ["set", "willSet", "didSet", "_modify"].contains($0.accessorSpecifier.text)
        }
        guard
            property.variable.bindingSpecifier.text != "let",
            !isReadOnly, !hasPrivateSetter, canWrite
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
        let access = property.variable
            .modifiers
            .first {
                [
                    "private",
                    "fileprivate",
                    "internal",
                    "package",
                    "public",
                    "open",
                ]
                .contains($0.name.text)
            }?.name
            .text

        let writeMethods = writeMethods(for: property, type: type, field: field, access: access)
        if access == "private" || access == "fileprivate" {
            return writeMethods
        }

        let name = attribute.nameSource(default: property.name)
        let documentation = attribute.documentationSource
        let readOnly = attribute.argument(named: "isReadOnly") ?? "false"
        let definition = """
        collector.addStoredProperty(\(property.owner.name).self, name: \(name), property: \(field),
            documentation: \(documentation), isReadOnly: \(readOnly))
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
        field: String,
        access: String?,
    ) -> [DeclSyntax] {
        let accessPrefix = access.map { $0 + " " } ?? ""
        let setterName = property.swiftSetterName

        let setter = DeclSyntax(stringLiteral: """
        \(accessPrefix)func \(setterName)(_ newValue: borrowing \(type)) throws {
            try self._pSetProperty(newValue, for: \(field))
        }
        """)

        let updater = DeclSyntax(stringLiteral: """
        \(accessPrefix)func \(setterName)(_ transform: (\(type)) throws -> \(type)) throws {
            let current = try self.\(property.swiftSpelling)
            let newValue = try transform(current)
            try self.\(setterName)(newValue)
        }
        """)

        return [setter, updater]
    }
}

// MARK: - PythonStoredPropertyMacro

struct PythonStoredPropertyMacro: AccessorMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [AccessorDeclSyntax] {
        let property = try PropertyDeclaration(declaration, in: context)
        let field = try property.storageSource().field
        return [
            AccessorDeclSyntax(stringLiteral: """
            get throws {
                try self._pGetProperty(\(field))
            }
            """),
        ]
    }
}

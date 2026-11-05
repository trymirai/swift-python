//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonReferenceMacro

struct PythonReferenceMacro {}

// MARK: PeerMacro

extension PythonReferenceMacro: PeerMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        let property = try PropertyDeclaration(declaration, in: context)

        let variable = property.variable
        let name = property.name
        let owner = property.owner

        guard variable.bindings.first?.accessorBlock == nil else {
            throw MacroExpansionErrorMessage("PythonReference requires a stored Field token.")
        }

        return [ExportRegistration(
            name: name + "_reference",
            definition:
            "collector.addReference(\(owner.name).self, name: \(String(reflecting: name)), field: { $0.\(name) })",
            in: context,
        ).declaration]
    }
}

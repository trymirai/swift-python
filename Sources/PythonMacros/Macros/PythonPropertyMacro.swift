//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - PythonPropertyMacro

struct PythonPropertyMacro {}

// MARK: PeerMacro

extension PythonPropertyMacro: PeerMacro {
    static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        let property = try PropertyDeclaration(declaration, in: context)
        let variable = property.variable
        let name = property.name
        let owner = property.owner

        let pythonName = attribute.argument().flatMap { $0 == "nil" ? nil : $0 }
            ?? String(reflecting: name)
        let documentation = attribute.argument(named: "documentation") ?? "nil"

        let isReference = variable.attributes.attribute(named: "PythonReference") != nil
        var isReadOnly = !isReference && variable.bindingSpecifier.text == "let"

        isReadOnly = isReadOnly
            || attribute.argument(named: "isReadOnly") == "true"
            || variable.modifiers.contains {
                $0.detail?.detail.text == "set"
                    && ["private", "fileprivate"].contains($0.name.text)
            }

        if let accessorBlock = variable.bindings.first?.accessorBlock {
            switch accessorBlock.accessors {
            case .getter:
                isReadOnly = true
            case let .accessors(accessors):
                isReadOnly = isReadOnly || !accessors
                    .contains {
                        ["set", "willSet", "didSet", "_modify"].contains($0.accessorSpecifier.text)
                    }
                if accessors.contains(where: { $0.effectSpecifiers?.asyncSpecifier != nil }) {
                    throw MacroExpansionErrorMessage(
                        "Python properties must have synchronous accessors.",
                    )
                }
            }
        }

        let hasThrowingGetter: Bool = if
            case let .accessors(accessors) = variable.bindings
            .first?
            .accessorBlock?
            .accessors
        {
            accessors.contains { $0.effectSpecifiers?.throwsClause != nil }
        } else {
            false
        }

        let getter = isReference ? "try instance.\(name).get(in: context)" : "\(hasThrowingGetter ? "try " : "")instance.\(name)"
        let setter: String = if isReadOnly {
            "nil"
        } else if isReference {
            "{ instance, decoder, context in try instance.\(name).set(decoder.get(), in: context) }"
        } else {
            "{ instance, decoder, _ in instance.\(name) = try decoder.get() }"
        }

        let definition = """
        collector.addProperty(\(owner.name).self, name: \(pythonName), documentation: \(documentation),
            getter: { instance, context, encoder in try encoder.encode(\(getter)) }, setter: \(setter))
        """
        return [ExportRegistration(name: name, definition: definition, in: context).declaration]
    }
}

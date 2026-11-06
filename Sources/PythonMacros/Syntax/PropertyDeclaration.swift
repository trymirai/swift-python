//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct PropertyDeclaration {
    let variable: VariableDeclSyntax
    let binding: PatternBindingSyntax
    let name: String
    let swiftSpelling: String
    let owner: ExportScope.Owner

    init(_ declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws {
        let scope = ExportScope(context)
        try scope.validate()

        guard
            let variable = declaration.as(VariableDeclSyntax.self),
            variable.bindings.count == 1,
            let binding = variable.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
            !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }),
            let owner = scope.owner,
            owner.isPythonClass || owner.isExtension
        else {
            throw MacroExpansionErrorMessage(
                "Python properties require a single instance property of a PythonClass.",
            )
        }

        self.variable = variable
        self.binding = binding
        self.name = identifier.identifier?.name ?? identifier.text
        self.swiftSpelling = identifier.trimmedDescription
        self.owner = owner
    }

    static func usesPythonStorage(_ variable: VariableDeclSyntax) -> Bool {
        guard variable.bindingSpecifier.text == "var" else {
            return false
        }

        switch variable.bindings.first?.accessorBlock?.accessors {
        case nil:
            return true
        case .getter:
            return false
        case let .accessors(accessors):
            return accessors.allSatisfy {
                ["willSet", "didSet"].contains($0.accessorSpecifier.text)
            }
        }
    }

    func storageType() throws -> String {
        guard
            variable.bindingSpecifier.text == "var",
            let type = binding.typeAnnotation?.type,
            binding.initializer == nil,
            binding.accessorBlock == nil,
            !variable.modifiers.contains(where: { $0.detail?.detail.text == "set" })
        else {
            throw MacroExpansionErrorMessage(
                """
                Declare a Python-stored property as a typed var with no initializer or accessors. \
                Set its initial value in init with try self.\(swiftSetterName)(value). \
                Use isReadOnly to restrict writes from Python.
                """,
            )
        }
        return type.concreteSpelling(owner: owner.name)
    }

    var swiftSetterName: String {
        "$" + name
    }

    var storageKey: String {
        "Swift::String(reflecting: \(owner.name).self) + \(String(reflecting: "." + swiftSpelling))"
    }
}

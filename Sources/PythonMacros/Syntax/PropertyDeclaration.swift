//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct PropertyDeclaration {
    let variable: VariableDeclSyntax
    let binding: PatternBindingSyntax
    let owner: ExportScope.Owner

    let name: String
    let swiftSpelling: String

    init(_ declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws {
        let scope = ExportScope(context)
        try scope.validate()

        guard
            let variable = declaration.as(VariableDeclSyntax.self),
            variable.bindings.count == 1,
            let binding = variable.bindings.first,
            let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
            !variable.modifiers.declaresStaticMember,
            let owner = scope.owner,
            owner.hasClassMacro || owner.isExtension
        else {
            throw MacroExpansionErrorMessage(
                "Python properties require a single instance property of a PythonClass.",
            )
        }

        self.variable = variable
        self.binding = binding
        self.owner = owner

        self.name = identifier.identifier?.name ?? identifier.text
        self.swiftSpelling = identifier.trimmedDescription
    }

    static func usesPStorage(_ variable: VariableDeclSyntax) -> Bool {
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

    var swiftSetterName: String {
        "$" + name
    }

    func storageSource() throws -> (type: String, field: String) {
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

        let typeSource = type.concreteSpelling(owner: owner.name)
        let key = "Swift::String(reflecting: \(owner.name).self) + \(String(reflecting: "." + swiftSpelling))"
        let field = "Python::Object.Property<(\(typeSource))>(\(key))"
        return (typeSource, field)
    }
}

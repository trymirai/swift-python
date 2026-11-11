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
            let owner = scope.owner,
            owner.isImportedClass || !variable.modifiers.declaresStaticMember,
            owner.isExportedClass || owner.isExtension || owner.isImportedClass
        else {
            throw MacroExpansionErrorMessage(
                "PythonProperty requires a member of a PythonImportedClass or PythonExportedClass.",
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

    var pythonNameSource: String {
        variable.attributes.attribute(named: "PythonProperty")?.nameSource(default: name)
            ?? String(reflecting: name)
    }

    var access: String? {
        let levels = ["private", "fileprivate", "internal", "package", "public", "open"]
        return variable.modifiers.first { levels.contains($0.name.text) }?.name.text
    }

    func importedTypeSource() throws -> String {
        guard let type = uninitializedVariableType else {
            throw MacroExpansionErrorMessage(
                "Declare an imported property as a typed var with no initializer or accessors.",
            )
        }
        return type.trimmedDescription
    }

    func storageSource() throws -> (type: String, field: String) {
        guard
            let type = uninitializedVariableType,
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

    var projectedAnnotationSource: String {
        // An opaque property type cannot be emitted as a metatype expression.
        guard
            let type = binding.typeAnnotation?.type,
            !type.tokens(viewMode: .sourceAccurate).contains(where: {
                $0.tokenKind == .keyword(.some)
            })
        else {
            return "nil"
        }

        return ".init((\(type.concreteSpelling(owner: owner.name))).self)"
    }

    private var uninitializedVariableType: TypeSyntax? {
        guard
            variable.bindingSpecifier.text == "var",
            binding.initializer == nil,
            binding.accessorBlock == nil
        else {
            return nil
        }

        return binding.typeAnnotation?.type
    }
}

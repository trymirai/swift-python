//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - ExportScope

struct ExportScope {
    private let lexicalContext: [Syntax]

    init(_ context: some MacroExpansionContext) {
        lexicalContext = context.lexicalContext
    }

    var owner: Owner? {
        var nearest: Syntax?
        var names = [String]()

        for scope in lexicalContext {
            if let extensionDeclaration = scope.as(ExtensionDeclSyntax.self) {
                let name = extensionDeclaration.extendedType.trimmedDescription
                if nearest == nil {
                    return Owner(name: name, scope: scope)
                }

                names.append(name)
                break
            }

            if let declaration = scope.exportTypeDeclaration {
                if nearest == nil {
                    nearest = scope
                }
                names.append(declaration.name.trimmedDescription)
            }
        }

        guard let nearest else {
            return nil
        }

        let qualifiedName = names.reversed().joined(separator: ".")
        return Owner(name: qualifiedName, scope: nearest)
    }

    func qualifiedName(of declaration: some DeclSyntaxProtocol) -> String {
        let name = declaration.exportTypeDeclaration?.name.trimmedDescription ?? "Self"
        return owner.map { "\($0.name).\(name)" } ?? name
    }

    func validate() throws {
        for scope in lexicalContext {
            if
                scope.is(FunctionDeclSyntax.self)
                || scope.is(InitializerDeclSyntax.self)
                || scope.is(ClosureExprSyntax.self)
            {
                throw MacroExpansionErrorMessage(
                    "Python exports require file scope or a concrete nominal type, not a local declaration.",
                )
            }
            if scope.exportTypeDeclaration?.genericParameterClause != nil {
                throw MacroExpansionErrorMessage(
                    "Python exports require a concrete, non-generic context.",
                )
            }
        }
    }
}

// MARK: ExportScope.Owner

extension ExportScope {
    struct Owner {
        let name: String
        let isExtension: Bool

        let isActor: Bool
        let isMainActorIsolated: Bool

        let isModule: Bool
        let isExportedClass: Bool
        let isImportedClass: Bool

        init?(name: String, scope: Syntax) {
            guard let declaration = scope.asProtocol(DeclGroupSyntax.self) else {
                return nil
            }

            let isExtension = scope.is(ExtensionDeclSyntax.self)
            let attributes = declaration.attributes

            func hasAttribute(_ name: String) -> Bool {
                !isExtension && attributes.attribute(named: name) != nil
            }

            self.name = name
            self.isExtension = isExtension

            isActor = scope.is(ActorDeclSyntax.self)
            isMainActorIsolated = hasAttribute("MainActor")

            isModule = hasAttribute("PythonExportedModule")
            isExportedClass = hasAttribute("PythonExportedClass")
            isImportedClass = hasAttribute("PythonImportedClass")
        }
    }
}

extension DeclModifierListSyntax {
    var declaresStaticMember: Bool {
        contains { $0.name.text == "static" || $0.name.text == "class" }
    }
}

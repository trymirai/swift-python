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

    struct Owner {
        let name: String

        let isExtension: Bool
        let isActor: Bool

        let isModule: Bool
        let hasClassMacro: Bool

        let isMainActorIsolated: Bool

        init?(name: String, scope: Syntax) {
            guard let declaration = scope.asProtocol(DeclGroupSyntax.self) else {
                return nil
            }
            self.name = name
            isExtension = scope.is(ExtensionDeclSyntax.self)
            isActor = scope.is(ActorDeclSyntax.self)

            let attributes = declaration.attributes
            isModule = !isExtension && attributes.attribute(named: "PythonModule") != nil
            hasClassMacro = !isExtension && attributes.attribute(named: "PythonClass") != nil
            isMainActorIsolated = !isExtension && attributes.attribute(named: "MainActor") != nil
        }
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

extension DeclModifierListSyntax {
    var declaresStaticMember: Bool {
        contains { $0.name.text == "static" || $0.name.text == "class" }
    }
}

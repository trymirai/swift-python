//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct ExportScope {
    private let lexicalContext: [Syntax]

    init(_ context: some MacroExpansionContext) {
        lexicalContext = context.lexicalContext
    }

    struct Owner {
        let name: String
        let isActor: Bool
        let isModule: Bool
        let isPythonClass: Bool
        let isExtension: Bool
        let isMainActorIsolated: Bool
    }

    var owner: Owner? {
        var nearest: Syntax?

        var names = [String]()
        for scope in lexicalContext {
            if let extensionDeclaration = scope.as(ExtensionDeclSyntax.self) {
                if nearest == nil {
                    return Owner(
                        name: extensionDeclaration.extendedType.trimmedDescription,
                        isActor: false,
                        isModule: false,
                        isPythonClass: false,
                        isExtension: true,
                        isMainActorIsolated: false,
                    )
                }

                names.append(extensionDeclaration.extendedType.trimmedDescription)
                break
            }

            if let declaration = scope.as(DeclSyntax.self), let name = declaration.typeName {
                if nearest == nil {
                    nearest = scope
                }
                names.append(name)
            }
        }

        guard let nearest, let group = nearest.asProtocol(DeclGroupSyntax.self) else {
            return nil
        }

        return Owner(
            name: names.reversed().joined(separator: "."),
            isActor: nearest.is(ActorDeclSyntax.self),
            isModule: group.attributes.attribute(named: "PythonModule") != nil,
            isPythonClass: group.attributes.attribute(named: "PythonClass") != nil,
            isExtension: false,
            isMainActorIsolated: group.attributes.attribute(named: "MainActor") != nil,
        )
    }

    func qualifiedName(of declaration: some DeclSyntaxProtocol) -> String {
        let name = declaration.typeName ?? "Self"
        return owner.map { "\($0.name).\(name)" } ?? name
    }

    func validate() throws {
        for scope in lexicalContext {
            if scope.is(FunctionDeclSyntax.self)
                || scope.is(InitializerDeclSyntax.self)
                || scope.is(ClosureExprSyntax.self)
            {
                throw MacroExpansionErrorMessage(
                    "Python exports require file scope or a concrete nominal type, not a local declaration.",
                )
            }
            if scope.as(StructDeclSyntax.self)?.genericParameterClause != nil
                || scope.as(ClassDeclSyntax.self)?.genericParameterClause != nil
                || scope.as(EnumDeclSyntax.self)?.genericParameterClause != nil
                || scope.as(ActorDeclSyntax.self)?.genericParameterClause != nil
            {
                throw MacroExpansionErrorMessage(
                    "Python exports require a concrete, non-generic context.",
                )
            }
        }
    }
}

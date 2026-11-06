//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxBuilder

// MARK: - ConcreteSelfRewriter

private final class ConcreteSelfRewriter: SyntaxRewriter {
    let owner: String

    init(_ owner: String) {
        self.owner = owner
    }

    override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
        node.name.text == "Self" ? TypeSyntax(stringLiteral: owner) : super.visit(node)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> ExprSyntax {
        node.baseName.text == "Self" ? ExprSyntax(stringLiteral: owner) : super.visit(node)
    }
}

extension ExprSyntax {
    func concreteSpelling(owner: String) -> String {
        ConcreteSelfRewriter(owner).rewrite(self).trimmedDescription
    }
}

extension TypeSyntax {
    func concreteSpelling(owner: String) -> String {
        var text = trimmedDescription
        for prefix in ["borrowing ", "consuming ", "inout "] {
            if text.hasPrefix(prefix) {
                text.removeFirst(prefix.count)
            }
        }

        return ConcreteSelfRewriter(owner)
            .rewrite(TypeSyntax(stringLiteral: text))
            .trimmedDescription
    }
}

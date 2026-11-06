//
//  Created by Anton Spivak
//

import SwiftSyntax

extension SyntaxProtocol {
    var exportTypeDeclaration: (any NamedDeclSyntax & WithGenericParametersSyntax)? {
        switch kind {
        case .enumDecl, .structDecl, .classDecl, .actorDecl:
            let declaration = Syntax(self).asProtocol(SyntaxProtocol.self)
            return declaration as? any NamedDeclSyntax & WithGenericParametersSyntax
        default:
            return nil
        }
    }
}

//
//  Created by Anton Spivak
//

import SwiftSyntax

extension DeclSyntaxProtocol {
    var typeName: String? {
        if let value = self.as(EnumDeclSyntax.self) {
            return value.name.trimmedDescription
        }
        if let value = self.as(StructDeclSyntax.self) {
            return value.name.trimmedDescription
        }
        if let value = self.as(ClassDeclSyntax.self) {
            return value.name.trimmedDescription
        }
        if let value = self.as(ActorDeclSyntax.self) {
            return value.name.trimmedDescription
        }
        return nil
    }
}

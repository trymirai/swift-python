//
//  Created by Anton Spivak
//

import SwiftSyntax

extension AttributeSyntax {
    func argument(named label: String? = nil) -> String? {
        guard case let .argumentList(arguments) = self.arguments else {
            return nil
        }
        return arguments.first { $0.label?.text == label }?.expression.trimmedDescription
    }
}

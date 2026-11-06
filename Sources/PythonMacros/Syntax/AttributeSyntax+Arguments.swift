//
//  Created by Anton Spivak
//

import SwiftSyntax

extension AttributeSyntax {
    func argument(named label: String? = nil) -> String? {
        guard case let .argumentList(arguments) = self.arguments else {
            return nil
        }
        let value = arguments.first { $0.label?.text == label }?.expression.trimmedDescription
        return value == "nil" ? nil : value
    }

    func nameSource(default name: String) -> String {
        argument() ?? String(reflecting: name)
    }

    var documentationSource: String {
        argument(named: "documentation") ?? "nil"
    }
}

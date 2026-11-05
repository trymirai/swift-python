//
//  Created by Anton Spivak
//

import SwiftSyntax

extension AttributeListSyntax {
    func attribute(named name: String) -> AttributeSyntax? {
        compactMap { $0.as(AttributeSyntax.self) }.first {
            $0.attributeName
                .trimmedDescription
                .split(whereSeparator: { $0 == "." || $0 == ":" })
                .last == Substring(name)
        }
    }
}

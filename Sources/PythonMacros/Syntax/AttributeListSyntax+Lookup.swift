//
//  Created by Anton Spivak
//

import SwiftSyntax

extension AttributeListSyntax {
    func attribute(named name: String) -> AttributeSyntax? {
        lazy.compactMap { $0.as(AttributeSyntax.self) }.first { attribute in
            attribute.attributeName
                .trimmedDescription
                .split(whereSeparator: { $0 == "." || $0 == ":" })
                .last == Substring(name)
        }
    }
}

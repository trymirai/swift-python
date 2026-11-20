//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxMacros

func importedArguments(for parameters: some Sequence<FunctionParameterSyntax>) throws -> String {
    var positional = [String]()
    var keywords = [String]()

    for parameter in parameters {
        let localName = parameter.secondName ?? parameter.firstName

        guard
            localName.text != "_",
            parameter.ellipsis == nil,
            !parameter.type.trimmedDescription.hasPrefix("inout ")
        else {
            throw MacroExpansionErrorMessage(
                "Imported Python parameters require names and fixed, encodable types.",
            )
        }

        if parameter.firstName.text == "_" {
            positional.append(localName.trimmedDescription)
        } else {
            let keyword = parameter.firstName.identifier?.name ?? parameter.firstName.text
            keywords.append("(\(String(reflecting: keyword)), \(localName.trimmedDescription))")
        }
    }

    let positionalList = positional.joined(separator: ", ")
    let keywordList = keywords.joined(separator: ", ")

    return "arguments: [\(positionalList)], keywords: [\(keywordList)]"
}

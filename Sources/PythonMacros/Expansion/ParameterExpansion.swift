//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxMacros

struct ParameterExpansion {
    private let index: Int
    private let bindingArguments: String

    let metadataSource: String
    let argumentSource: String

    init(
        _ parameter: FunctionParameterSyntax,
        index: Int,
        owner: String,
        hasReceiver: Bool,
    ) throws {
        let isMutableSpan = try Self.requiresMutableSpan(parameter)
        self.index = index

        let type = "(\(parameter.type.concreteSpelling(owner: owner))).self"
        let defaultValueSource = parameter
            .defaultValue
            .map { ", default: { \($0.value.concreteSpelling(owner: owner)) }" } ?? ""
        let parameterIndex = index + (hasReceiver ? 1 : 0)
        bindingArguments = "\(type), parameter: \(parameterIndex)\(defaultValueSource)"

        let name = parameter.secondName?.text ?? parameter.firstName.text
        let pName = name == "_" ? "arg\(index)" : name
        let isUnlabeled = parameter.firstName.text == "_"

        // Select the annotation overload while the declared parameter type is still concrete.
        metadataSource = """
        .init(\(String(reflecting: pName)), as: .init(\(type)),
              hasDefaultValue: \(parameter.defaultValue != nil), isUnlabeled: \(isUnlabeled))
        """

        let label = isUnlabeled ? "" : "\(parameter.firstName.trimmedDescription): "
        argumentSource = "\(label)\(isMutableSpan ? "&" : "")__value\(index)"
    }

    var preparationSource: String {
        """
        var __argument\(index) = try arguments.prepare(\(bindingArguments))
        try __argument\(index).validate()
        """
    }

    func wrapping(_ expression: String, isAsynchronous: Bool) -> String {
        let projection = if isAsynchronous {
            "arguments.withArgument(\(bindingArguments))"
        } else {
            "__argument\(index).withValue"
        }
        return """
        return try \(projection) { __value\(index) in
            \(expression)
        }
        """
    }

    private static func requiresMutableSpan(_ parameter: FunctionParameterSyntax) throws -> Bool {
        let spelling = parameter.type.trimmedDescription
        let isMutableSpan = spelling.hasPrefix("inout ") && spelling.contains("MutableSpan<")
        guard
            parameter.ellipsis == nil,
            !spelling.hasPrefix("consuming "),
            !spelling.hasPrefix("inout ") || isMutableSpan
        else {
            throw MacroExpansionErrorMessage(
                "Python parameters do not support variadics, consuming or general inout arguments.",
            )
        }
        return isMutableSpan
    }
}

//
//  Created by Anton Spivak
//

import SwiftSyntax
import SwiftSyntaxMacros

struct ParameterExpansion {
    private let index: Int
    private let typeName: String
    private let defaultValueSource: String
    private let parameterIndex: Int
    let metadataSource: String
    let argumentSource: String

    init(
        _ parameter: FunctionParameterSyntax,
        index: Int,
        owner: String,
        hasReceiver: Bool,
    ) throws {
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
        self.index = index

        typeName = parameter.type.concreteSpelling(owner: owner)
        defaultValueSource = parameter
            .defaultValue
            .map { ", default: { \($0.value.concreteSpelling(owner: owner)) }" } ?? ""
        parameterIndex = index + (hasReceiver ? 1 : 0)

        let name = parameter.secondName?.text ?? parameter.firstName.text
        let pythonName = name == "_" ? "arg\(index)" : name
        metadataSource = ".init(\(String(reflecting: pythonName)), as: (\(typeName)).self, hasDefaultValue: \(parameter.defaultValue != nil))"

        let label = parameter.firstName.text == "_" ? "" : "\(parameter.firstName.trimmedDescription): "
        argumentSource = "\(label)\(isMutableSpan ? "&" : "")__value\(index)"
    }

    var preparationSource: String {
        """
        var __argument\(index) = try arguments.prepare((\(typeName)).self, parameter: \(parameterIndex)\(defaultValueSource))
        try __argument\(index).validate()
        """
    }

    func wrapping(_ expression: String, isAsynchronous: Bool) -> String {
        let projection = if isAsynchronous {
            "arguments.withArgument((\(typeName)).self, parameter: \(parameterIndex)\(defaultValueSource))"
        } else {
            "__argument\(index).withValue"
        }
        return """
        return try \(projection) { __value\(index) in
            \(expression)
        }
        """
    }
}

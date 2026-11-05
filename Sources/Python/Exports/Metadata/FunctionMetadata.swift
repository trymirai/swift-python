//
//  Created by Anton Spivak
//

// MARK: - FunctionMetadata

struct FunctionMetadata {
    let value: Module.Function
}

// MARK: Encodable

extension FunctionMetadata: Encodable {
    func encode(to encoder: inout Encoder) throws {
        let isAsynchronous = switch value.body {
        case .synchronous:
            false
        case .asynchronous:
            true
        }

        try encoder.encode(value.name, at: 0)
        try encoder.encode(value.documentation, at: 1)
        try encoder.encode(value.returnAnnotation, at: 2)
        try encoder.encode(isAsynchronous, at: 3)

        try encoder.encode(
            value.parameters.filter { !$0.isInjected }.map { ParameterMetadata(value: $0) },
            at: 4,
        )

        try encoder.encode(value.usesSwiftBinding, at: 5)
    }
}

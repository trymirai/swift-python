//
//  Created by Anton Spivak
//

// MARK: - ParameterMetadata

struct ParameterMetadata {
    let value: Module.Function.Parameter
}

// MARK: Encodable

extension ParameterMetadata: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(value.name, at: 0)
        try encoder.encode(value.annotation, at: 1)
        try encoder.encode(value.hasDefaultValue, at: 2)
        try encoder.encode(value.defaultValue, at: 3)
    }
}

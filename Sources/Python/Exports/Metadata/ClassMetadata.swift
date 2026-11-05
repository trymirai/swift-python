//
//  Created by Anton Spivak
//

// MARK: - ClassMetadata

struct ClassMetadata {
    let value: Module.Class
}

// MARK: Encodable

extension ClassMetadata: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(value.key, at: 0)
        try encoder.encode(value.superclassKey, at: 1)
        try encoder.encode(value.name, at: 2)
        try encoder.encode(value.documentation, at: 3)
        try encoder.encode(value.initializer.map { FunctionMetadata(value: $0) }, at: 4)
        try encoder.encode(value.methods.map { FunctionMetadata(value: $0) }, at: 5)
        try encoder.encode(value.properties.map { PropertyMetadata(value: $0) }, at: 6)
    }
}

//
//  Created by Anton Spivak
//

// MARK: - PropertyMetadata

struct PropertyMetadata {
    let value: Module.Class.Property
}

// MARK: Encodable

extension PropertyMetadata: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(value.name, at: 0)
        try encoder.encode(value.documentation, at: 1)
        try encoder.encode(FunctionMetadata(value: value.getter), at: 2)
        try encoder.encode(value.setter.map { FunctionMetadata(value: $0) }, at: 3)
    }
}

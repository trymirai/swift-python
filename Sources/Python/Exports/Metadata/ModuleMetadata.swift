//
//  Created by Anton Spivak
//

// MARK: - ModuleMetadata

struct ModuleMetadata {
    let value: Module
}

// MARK: Encodable

extension ModuleMetadata: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(value.name, at: 0)
        try encoder.encode(value.documentation, at: 1)
        try encoder.encode(value.source, at: 2)
        try encoder.encode(value.functions.map { FunctionMetadata(value: $0) }, at: 3)
        try encoder.encode(value.classes.map { ClassMetadata(value: $0) }, at: 4)
    }
}

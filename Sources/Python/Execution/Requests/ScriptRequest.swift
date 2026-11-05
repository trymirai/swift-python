//
//  Created by Anton Spivak
//

// MARK: - ScriptRequest

struct ScriptRequest {
    let source: String
    let arguments: [String]
}

// MARK: Encodable

extension ScriptRequest: Encodable {
    func encode(to encoder: inout Encoder) throws {
        try encoder.encode(source, forKey: "source")
        try encoder.encode(arguments, forKey: "arguments")
    }
}

//
//  Created by Anton Spivak
//

// MARK: - ExecutionReply

struct ExecutionReply: Sendable {
    let output: Output
    let traceback: String
}

// MARK: Decodable

extension ExecutionReply: Decodable {
    init(from decoder: borrowing Decoder) throws {
        output = Output(
            stdout: try decoder.decode(String.self, at: 0),
            stderr: try decoder.decode(String.self, at: 1),
        )
        traceback = try decoder.decode(String.self, at: 2)
    }
}

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
        output = Output(stdout: try decoder[0].get(), stderr: try decoder[1].get())
        traceback = try decoder[2].get()
    }
}

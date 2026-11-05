//
//  Created by Anton Spivak
//

/// The text captured in memory during one execution.
/// Streams redirected to files through `StandardIO` have empty strings here.
public struct Output: Sendable {
    public let stdout: String
    public let stderr: String

    public enum Stream: Sendable {
        case stdout
        case stderr
    }

    static let empty: Output = .init(stdout: "", stderr: "")
}

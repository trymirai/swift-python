//
//  Created by Anton Spivak
//

/// The outcome of an evaluation or script, including output captured before it ended.
public struct Execution: Sendable {
    public let output: Output
    public let end: End

    public enum End: Sendable, Equatable {
        case finished

        /// The execution was cancelled.
        case stopped

        case timedOut
    }
}

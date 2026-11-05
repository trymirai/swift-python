//
//  Created by Anton Spivak
//

// MARK: - ExecutionError

/// An exception or interruption with any output captured before execution ended.
public enum ExecutionError: Swift.Error {
    case exception(traceback: String, output: Output)
    case stopped(Output)
    case timedOut(Output)
}

// MARK: CustomStringConvertible

extension ExecutionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .exception(traceback, _):
            traceback
        case .stopped:
            "Stopped by user"
        case .timedOut:
            "Python execution timed out."
        }
    }
}

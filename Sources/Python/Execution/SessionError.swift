//
//  Created by Anton Spivak
//

// MARK: - SessionError

public enum SessionError: Swift.Error {
    case closed

    /// Reset the session before retrying a package change that affects loaded modules.
    case resetRequired(modules: [String])
}

// MARK: CustomStringConvertible

extension SessionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .closed:
            "The Python session is closed."
        case let .resetRequired(modules):
            "Reset the session before replacing loaded modules: \(modules.joined(separator: ", "))."
        }
    }
}

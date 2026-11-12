//
//  Created by Anton Spivak
//

// MARK: - Session.History

public extension Session {
    /// Input sources and Python results retained by an interactive session.
    struct History: Sendable {
        /// Evicting an input also removes its redirected source file, if any.
        public let inputs: Retention
        public let outputs: Retention

        public init(
            inputs: Retention = .unlimited,
            outputs: Retention = .last(32),
        ) {
            self.inputs = inputs
            self.outputs = outputs
        }
    }
}

// MARK: - Session.History.Retention

public extension Session.History {
    /// Limits entries, rather than the size of the retained Python objects.
    enum Retention: Sendable {
        /// Retains the last n entries. The count must be positive.
        case last(Int)
        case unlimited

        var limit: Int {
            switch self {
            case let .last(count):
                count
            case .unlimited:
                -1
            }
        }

        func validate() throws {
            if case let .last(count) = self, count <= 0 {
                throw Runtime.Failure("A history entry limit must be positive.")
            }
        }
    }
}

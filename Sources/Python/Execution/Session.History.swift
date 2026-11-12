//
//  Created by Anton Spivak
//

import Synchronization

// MARK: - Session.Reservation

public extension Session {
    /// A single-use history number for an interactive evaluation in this session.
    final class Reservation: Sendable {
        init(number: Int, history: History.Store) {
            self.number = number
            self.history = history
        }

        public let number: Int

        private let history: History.Store
        private let isConsumed: Mutex<Bool> = .init(false)

        func claim(in history: History.Store) throws -> Int {
            guard self.history === history else {
                throw Runtime.Failure("The reservation belongs to another Python session.")
            }
            return try isConsumed.withLock { consumed in
                guard !consumed else {
                    throw Runtime.Failure("The execution reservation has already been used.")
                }
                consumed = true
                return number
            }
        }
    }

    /// Reserves a history number without running Python or waiting for the operation queue.
    /// History must be enabled. Pass the reservation to one evaluate call; unused numbers
    /// remain gaps. Reset preserves the counter and outstanding reservations.
    nonisolated func reserve() throws -> Reservation {
        guard let history else {
            throw Runtime.Failure("Execution reservations require session history.")
        }
        return try Reservation(number: history.reserveNumber(), history: history)
    }
}

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

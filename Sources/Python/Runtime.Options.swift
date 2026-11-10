//
//  Created by Anton Spivak
//

// MARK: - Runtime.Options

public extension Runtime {
    struct Options: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// Enables Python subprocesses owned by the current execution.
        /// Child programs use their operating-system file access.
        public static let subprocesses: Self = .init(rawValue: 1 << 0)
    }
}

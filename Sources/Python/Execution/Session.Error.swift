//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - Session.Error

public extension Session {
    enum Error: Swift::Error {
        case closed

        /// A callback tried to enter a session that already has an operation.
        case busy
    }
}

// MARK: - Session.Error + CustomStringConvertible

extension Session.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .closed:
            "The Python session is closed."
        case .busy:
            "The Python session is busy. A callback can only enter an idle session."
        }
    }
}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension Session.Error: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

#endif

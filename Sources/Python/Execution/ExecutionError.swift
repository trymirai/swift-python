//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - ExecutionError

/// An uncaught Python exception and the output captured before execution ended.
public struct ExecutionError: Swift::Error {
    public let traceback: String
    public let output: Output
}

// MARK: CustomStringConvertible

extension ExecutionError: CustomStringConvertible {
    public var description: String {
        traceback
    }
}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension ExecutionError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

#endif

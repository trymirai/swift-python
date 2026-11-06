//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - Exception

/// A named Python exception from an object operation or raised by a Swift callback.
public struct Exception: Swift::Error {
    public let name: String
    public let message: String

    /// In Swift callbacks, `name` selects a Python `Exception` subclass from builtins.
    /// Other names raise Python `RuntimeError`.
    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

// MARK: CustomStringConvertible

extension Exception: CustomStringConvertible {
    public var description: String {
        message
    }
}

#if canImport(FoundationEssentials) || canImport(Foundation)

// MARK: LocalizedError

extension Exception: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

#endif

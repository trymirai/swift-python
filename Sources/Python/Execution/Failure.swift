//
//  Created by Anton Spivak
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif canImport(Foundation)
import Foundation
#endif

// MARK: - Failure

/// A failure reported by the interpreter or the Swift bridge.
public struct Failure: Swift.Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case exception(ExceptionName)
        case busy
        case closed
        case runtime
    }

    public let kind: Kind
    public let message: String
    public let traceback: String?

    /// Output captured before a Python evaluation failed.
    public let output: Output?

    /// The history number assigned to the failed evaluation, when recorded.
    public internal(set) var number: Int?

    public var description: String {
        traceback ?? message
    }

    /// Throwing this from a Swift export raises the named `Exception` subclass in Python's
    /// builtins. An unknown name falls back to `RuntimeError`.
    public init(_ name: ExceptionName, message: String) {
        self.init(kind: .exception(name), message: message)
    }

    init(_ message: String) {
        self.init(kind: .runtime, message: message)
    }

    init(
        kind: Kind,
        message: String,
        traceback: String? = nil,
        output: Output? = nil,
    ) {
        self.kind = kind
        self.message = message
        self.traceback = traceback

        self.output = output
    }

    static let closed: Self = .init(
        kind: .closed,
        message: "The Python session or callback is closed.",
    )

    static let busy: Self = .init(
        kind: .busy,
        message: "The Python session is busy. A callback can only enter an idle session.",
    )
}

#if canImport(FoundationEssentials) || canImport(Foundation)
extension Failure: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
#endif

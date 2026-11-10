//
//  Created by Anton Spivak
//

// On a throwing return path Swift 6.4 can destroy an uninitialized opaque
// nonescapable result. Store failures in initialized projections and validate
// each projection before preparing the next argument.

/// Compiler support. Preparation owns or pins inputs before any borrowed view is issued.
@_documentation(visibility: internal)
public protocol _PArgument<Value>: ~Copyable, ~Escapable {
    associatedtype Value: ~Copyable, ~Escapable

    borrowing func validate() throws
    mutating func withValue<Result: ~Copyable>(
        _ body: (inout Value) throws -> Result,
    ) throws -> Result
}

//
//  Created by Anton Spivak
//

// Swift 6.4 can destroy an uninitialized opaque nonescapable result on a
// throwing return path. Return a fully initialized projection, then validate it
// before preparing the next argument. No Python exception remains pending.

/// Compiler support. Preparation owns or pins inputs before any borrowed view is issued.
@_documentation(visibility: internal)
public protocol _PArgument<Value>: ~Copyable, ~Escapable {
    associatedtype Value: ~Copyable, ~Escapable

    borrowing func validate() throws
    mutating func withValue<Result: ~Copyable>(
        _ body: (inout Value) throws -> Result,
    ) throws -> Result
}

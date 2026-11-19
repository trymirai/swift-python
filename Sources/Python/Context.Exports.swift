//
//  Created by Anton Spivak
//

public extension Context {
    /// Swift exports installed in this interpreter generation.
    var exports: Exports {
        .init(context: self)
    }

    // MARK: - Context.Exports

    struct Exports: Sendable {
        fileprivate let context: Context

        /// Returns the installed Swift-exported Python classes in unspecified order.
        /// Use inside `Session.enqueue` or an active Swift export. References become
        /// invalid after reset or close. Sessions without exported classes return an empty array.
        public func classes() throws -> [Reference] {
            try context.withAccess { context in
                try context.checkAccess().classRegistry?.classes() ?? []
            }
        }
    }
}

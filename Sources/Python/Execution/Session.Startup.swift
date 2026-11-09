//
//  Created by Anton Spivak
//

// MARK: - Session.Startup

public extension Session {
    /// Chooses how the session initializes its namespace on first use and after reset.
    enum Startup: Sendable {
        case source(String)

        /// Imports a flat-layout project package and resolves dependencies from its root.
        case project(directory: String, module: String)

        /// Uses the imported module's globals as the interactive namespace.
        case module(String)

        var projectDirectory: String? {
            if case let .project(directory, _) = self {
                directory
            } else {
                nil
            }
        }
    }
}

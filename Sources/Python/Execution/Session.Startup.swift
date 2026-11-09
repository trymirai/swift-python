//
//  Created by Anton Spivak
//

// MARK: - Session.Startup

public extension Session {
    /// Chooses how the session initializes its namespace on first use and after reset.
    enum Startup: Sendable {
        case source(String)

        /// Resolves dependencies from a project and imports a module from it.
        ///
        /// A missing name selects the first top-level package with `__init__.py` in name order.
        /// A named module can also be loaded from an explicit `importPaths` directory within the project.
        /// Startup fails if the selected module is unavailable in the project.
        case project(directory: String, module: String? = nil)

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

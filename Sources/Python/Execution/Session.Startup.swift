//
//  Created by Anton Spivak
//

// MARK: - Session.Startup

public extension Session {
    /// Prepares the persistent namespace before the first interactive block.
    enum Startup: Sendable {
        case source(String)

        /// A flat-layout project and the package to import from its root.
        case project(directory: String, module: String)

        /// A module already supplied by the application's package sources.
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

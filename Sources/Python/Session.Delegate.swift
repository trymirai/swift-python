//
//  Created by Anton Spivak
//

// MARK: - Session.Delegate

public extension Session {
    /// Receives file access requests. A session retains its delegate until it closes.
    protocol Delegate: Sendable {
        /// Decides on standalone script reads and requests outside the session's read grants.
        /// Returning `false` produces `Errno.permissionDenied` for a script source and
        /// `PermissionError` during Python execution.
        ///
        /// Handle cancellation promptly. Use an idle session for Python work needed to make
        /// the decision, and isolate permission prompts to `@MainActor` when they use the UI.
        func shouldAllowFileAccess(_ request: FileAccessRequest) async throws -> Bool
    }
}

//
//  Created by Anton Spivak
//

// MARK: - Session.Delegate

public extension Session {
    /// Receives requests from this session. The session retains its delegate until it closes.
    protocol Delegate: Sendable {
        /// Decides whether Python may proceed with a pending file open.
        /// Returning `false` raises `PermissionError`. The default permits the open.
        /// The session is waiting for this result. Handle cancellation promptly and
        /// use an idle session for any Python work needed to make the decision.
        /// For UI work, declare `@MainActor` on the implementing method.
        func session(
            _ session: Session,
            shouldOpenFile request: FileOpenRequest,
        ) async throws -> Bool
    }
}

public extension Session.Delegate {
    func session(
        _ session: Session,
        shouldOpenFile request: Session.FileOpenRequest,
    ) async throws -> Bool {
        true
    }
}

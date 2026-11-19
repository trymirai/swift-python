//
//  Created by Anton Spivak
//

public extension Runtime {
    /// Prepared dependencies for `Runtime.session(_:module:)`.
    /// Keep the package sources available for as long as a session uses them.
    struct ProjectResources: Sendable {
        let project: Path

        public let sources: [PackageSource]

        /// Identifies the resolution inputs. An update can keep this fingerprint.
        public let fingerprint: String

        /// The directory and manifest paths for this resolution.
        public let paths: Paths.Environment
    }
}

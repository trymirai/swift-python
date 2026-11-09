//
//  Created by Anton Spivak
//

public import SystemPackage

public extension Session {
    /// An operation on a resolved path whose parent has been pinned for the syscall.
    struct FileAccessRequest: Sendable {
        /// The absolute path resolved before the access decision.
        public let path: FilePath

        public let operation: Operation

        /// Whether the entry existed when the request was made.
        public let exists: Bool

        /// Swift data supplied by the caller for this operation.
        public let scope: (any Sendable)?

        public enum Operation: Sendable, Equatable {
            case open(mode: FileDescriptor.AccessMode, options: FileDescriptor.OpenOptions)

            case metadata
            case enumerate
            case createDirectory
            case remove

            case renameSource
            case renameDestination
        }
    }
}

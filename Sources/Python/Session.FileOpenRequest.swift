//
//  Created by Anton Spivak
//

public import SystemPackage

public extension Session {
    /// A pending path-based open through Python's file I/O or `os.open`.
    struct FileOpenRequest: Sendable {
        /// The absolute path at the time of the request, without resolving symbolic links.
        public let path: FilePath

        public let mode: FileDescriptor.AccessMode
        public let options: FileDescriptor.OpenOptions
    }
}

//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import SystemPackage

// MARK: - StandardIO

/// Files supplied by the host for one evaluation or script execution.
/// Use absolute paths and a separate file for each active writer. The host
/// creates the parent directories. Python appends to output files and reads EOF
/// when input is omitted.
public struct StandardIO: Sendable {
    public let stdin: String?
    public let stdout: String?
    public let stderr: String?
    public let traceback: String?

    public init(
        stdin: String? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        traceback: String? = nil,
    ) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.traceback = traceback
    }

    /// Reads currently available bytes without entering the session's executor.
    /// An empty read indicates the current end of the file, not task completion.
    /// Continue from offset + the returned byte count; text may span reads.
    public func read(
        _ stream: Output.Stream,
        from offset: Int64 = 0,
        maximumByteCount: Int = 64 * 1024,
    ) async throws -> [UInt8] {
        let path = switch stream {
        case .stdout:
            stdout
        case .stderr:
            stderr
        }

        guard let path else {
            throw RuntimeFailure("The selected stream has no output file.")
        }

        guard !path.utf8.contains(0) else {
            throw RuntimeFailure("A standard I/O path must not contain NUL characters.")
        }
        guard offset >= 0, let byteCount = UInt32(exactly: maximumByteCount) else {
            throw RuntimeFailure("Expected a nonnegative file offset and a bounded byte count.")
        }

        if byteCount == 0 {
            return []
        }

        return try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(path)) { handle in
            let buffer = try await handle.readChunk(
                fromAbsoluteOffset: offset,
                length: .bytes(Int64(byteCount)),
            )
            return Array(buffer.readableBytesView)
        }
    }
}

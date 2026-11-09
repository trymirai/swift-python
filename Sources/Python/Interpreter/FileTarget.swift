//
//  Created by Anton Spivak
//

internal import libcpython
internal import SystemPackage

#if canImport(Darwin)
private import Darwin
#elseif canImport(Glibc)
private import Glibc
#elseif canImport(Musl)
private import Musl
#endif

// MARK: - FileTarget

// The target is immutable and owns its pinned parent descriptor.
@safe
final class FileTarget: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(_ path: FilePath) throws {
        let pinned = unsafe path.withPlatformString { unsafe CPython_PinFileTarget(
            $0,
            AT_FDCWD,
            true,
        ) }
        guard let pinned = unsafe pinned else {
            throw Errno(rawValue: errno)
        }
        unsafe pointer = pinned
    }

    deinit {
        unsafe CPython_FreeFileTarget(pointer)
    }

    var path: FilePath {
        unsafe FilePath(platformString: CPython_FileTargetPath(pointer))
    }

    var exists: Bool {
        unsafe CPython_FileTargetExists(pointer)
    }

    func openForReading() throws -> FileDescriptor {
        let descriptor = unsafe CPython_OpenFileTarget(pointer, O_RDONLY, 0)
        guard descriptor >= 0 else {
            throw Errno(rawValue: errno)
        }
        return FileDescriptor(rawValue: descriptor)
    }
}

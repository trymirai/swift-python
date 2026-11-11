//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization
internal import SystemPackage

extension Session.Control {
    /// Wakes the Python event loop. A Swift export can also send a pending-work byte.
    final class Pipe: Sendable {
        private struct Descriptors {
            var reader: Int32?
            var writer: Int32?
        }

        private let descriptors: Mutex<Descriptors>

        init() throws {
            var reader: Int32 = -1
            var writer: Int32 = -1

            // Swift System's closeOnExec pipe option requires Apple OS 27.
            let status = unsafe CPython_NewPipe(&reader, &writer)
            guard status == 0 else {
                throw Errno(rawValue: status)
            }

            self.descriptors = .init(Descriptors(reader: reader, writer: writer))
        }

        deinit {
            close()
        }

        func readDescriptor() throws -> FileDescriptor {
            guard let reader = descriptors.withLock({ $0.reader }) else {
                throw Errno.badFileDescriptor
            }
            return FileDescriptor(rawValue: reader)
        }

        func notify() throws {
            // Hold the descriptor lock through the write so signal() cannot close the writer.
            try descriptors.withLock { owned in
                guard let writer = owned.writer else {
                    throw Errno.badFileDescriptor
                }

                let descriptor = FileDescriptor(rawValue: writer)
                var byte: UInt8 = 1
                try withUnsafeBytes(of: &byte) { buffer in
                    guard unsafe try descriptor.write(buffer) == 1 else {
                        throw Errno.ioError
                    }
                }
            }
        }

        func consumeNotification() throws {
            let reader = try readDescriptor()

            var byte: UInt8 = 0
            try withUnsafeMutableBytes(of: &byte) { buffer in
                guard unsafe try reader.read(into: buffer) == 1 else {
                    throw Errno.ioError
                }
            }
        }

        func signal() {
            let descriptor = descriptors.withLock { exchange(&$0.writer, with: nil) }
            Self.closeDescriptor(descriptor)
        }

        func close() {
            let owned = descriptors.withLock { exchange(&$0, with: Descriptors()) }
            Self.closeDescriptor(owned.writer)
            Self.closeDescriptor(owned.reader)
        }

        private static func closeDescriptor(_ descriptor: Int32?) {
            if let descriptor {
                // Retrying after an error can close a reused descriptor.
                try? FileDescriptor(rawValue: descriptor).close()
            }
        }
    }
}

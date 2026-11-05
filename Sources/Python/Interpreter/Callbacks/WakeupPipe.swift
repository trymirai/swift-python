//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization
internal import SystemPackage

// MARK: - WakeupPipe

/// Wakes the Python event loop on EOF. Swift tasks only access the write end.
final class WakeupPipe: Sendable {
    private struct Descriptors {
        var reader: Int32?
        var writer: Int32?
    }

    private let descriptors: Mutex<Descriptors>

    var reader: Int32 {
        descriptors.withLock { $0.reader ?? -1 }
    }

    init() throws {
        var reader: Int32 = -1
        var writer: Int32 = -1
        // Swift System's closeOnExec pipe option requires Apple OS 27.
        // Keep this initializer for the 26.4 deployment baseline.
        let status = unsafe CPython_NewPipe(&reader, &writer)
        guard status == 0 else {
            throw Errno(rawValue: status)
        }
        self.descriptors = .init(Descriptors(reader: reader, writer: writer))
    }

    deinit {
        close()
    }

    func signal() {
        let descriptor = descriptors.withLock { descriptors in
            defer {
                descriptors.writer = nil
            }
            return descriptors.writer
        }
        if let descriptor {
            // Closing is final; retrying after an error can close a reused descriptor.
            try? FileDescriptor(rawValue: descriptor).close()
        }
    }

    func close() {
        let descriptors = self.descriptors.withLock { descriptors in
            defer {
                descriptors = Descriptors()
            }
            return descriptors
        }
        if let writer = descriptors.writer {
            try? FileDescriptor(rawValue: writer).close()
        }
        if let reader = descriptors.reader {
            try? FileDescriptor(rawValue: reader).close()
        }
    }
}

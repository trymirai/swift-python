//
//  Created by Anton Spivak
//

internal import libcpython
internal import SystemPackage

// MARK: - Session.Control.Subprocesses

extension Session.Control {
    // Native synchronization protects process admission and signalling. Only the session
    // executor registers or waits for children, and Control retains the handle until they join.
    @safe
    final class Subprocesses: @unchecked Sendable {
        let handle: OpaquePointer

        init() throws {
            guard let handle = unsafe CPython_NewSubprocesses() else {
                throw Runtime.Failure("Unable to allocate the Python subprocess scope.")
            }
            unsafe self.handle = handle
        }

        deinit {
            unsafe CPython_FreeSubprocesses(handle)
        }

        func hasOpenPipes(in files: Interpreter.FileAccess) -> Bool {
            unsafe CPython_SubprocessesHaveOpenPipes(handle, files.descriptors)
        }

        func stop() {
            unsafe CPython_StopSubprocesses(handle)
        }

        func join() throws {
            let error = unsafe CPython_JoinSubprocesses(handle)
            guard error == 0 else {
                throw Errno(rawValue: error)
            }
        }
    }
}

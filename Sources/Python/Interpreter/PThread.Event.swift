//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - PThread.Event

extension PThread {
    // The C API synchronizes event state. The thread check reads thread-local storage.
    @safe
    struct Event: ~Copyable, @unchecked Sendable {
        private let pointer: OpaquePointer

        init() throws {
            guard let pointer = unsafe CPython_ThreadEvent_New() else {
                throw Runtime.Failure("Unable to allocate a Python thread event.")
            }
            unsafe self.pointer = pointer
        }

        deinit {
            unsafe CPython_ThreadEvent_Free(pointer)
        }

        var isCurrent: Bool {
            unsafe CPython_ThreadEvent_IsCurrent(pointer)
        }

        borrowing func bind() {
            unsafe CPython_ThreadEvent_Bind(pointer)
        }

        borrowing func signal() {
            unsafe CPython_ThreadEvent_Signal(pointer)
        }

        borrowing func wait() {
            unsafe CPython_ThreadEvent_Wait(pointer)
        }
    }
}

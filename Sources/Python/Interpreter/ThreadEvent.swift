//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - ThreadEvent

// One executor owns the event. Only the C API touches its mutex-protected state;
// checking the current thread reads thread-local storage instead of shared memory.
@safe
struct ThreadEvent: ~Copyable, @unchecked Sendable {
    private let pointer: OpaquePointer

    init() throws {
        guard let pointer = unsafe CPython_ThreadEvent_New() else {
            throw RuntimeFailure("Unable to allocate a Python thread event.")
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

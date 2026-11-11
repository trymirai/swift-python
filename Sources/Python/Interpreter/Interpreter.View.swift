//
//  Created by Anton Spivak
//

internal import libcpython

extension Interpreter {
    // CPython views may cross threads and remain valid after their interpreter closes.
    @safe
    final class View: @unchecked Sendable {
        private let pointer: OpaquePointer
        private let key: UInt

        @unsafe
        init(state: UnsafeMutablePointer<PyThreadState>) throws {
            guard let pointer = unsafe CPython_NewInterpreterView(state) else {
                throw Runtime.Failure("Unable to retain the Python interpreter view.")
            }
            unsafe self.pointer = pointer
            key = unsafe CPython_InterpreterKey(state)
        }

        deinit {
            unsafe PyInterpreterView_Close(pointer)
        }

        @unsafe
        func withStorage<Result: ~Copyable>(
            _ body: (Storage, OpaquePointer) throws -> Result,
        ) throws -> Result {
            // Views and finalization guards outlive transactional Python allocations.
            let previousHeap = unsafe CPython_BindHeap(nil)
            defer { _ = unsafe CPython_BindHeap(previousHeap) }
            guard let guardPointer = unsafe PyInterpreterGuard_FromView(pointer) else {
                throw Reference.wrongInterpreter()
            }
            defer { unsafe PyInterpreterGuard_Close(guardPointer) }
            guard let storage = Storage.lookup(key) else {
                throw Session.Error.closed
            }
            return unsafe try body(storage, guardPointer)
        }
    }
}

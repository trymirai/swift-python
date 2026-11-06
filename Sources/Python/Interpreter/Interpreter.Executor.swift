//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization
internal import SystemPackage

// MARK: - Interpreter.Executor

extension Interpreter {
    // Runs Swift actor jobs on the same OS thread for the lifetime of a session.
    final class Executor: SerialExecutor {
        private struct Queue {
            var jobs: [UnownedJob] = []
            var isFinishing: Bool = false
        }

        private let queue: Mutex<Queue> = .init(Queue())
        private let event: Event

        init() throws {
            self.event = try Event()
            let context = unsafe Unmanaged.passRetained(self).toOpaque()
            let status = unsafe CPython_StartThread({ context in
                unsafe Interpreter.Executor.enter(context)
            }, context)
            if status != 0 {
                unsafe Unmanaged<Interpreter.Executor>.fromOpaque(context).release()
                throw Errno(rawValue: status)
            }
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let queued = UnownedJob(job)
            let wake = queue.withLock { queue in
                precondition(!queue.isFinishing)
                let wake = queue.jobs.isEmpty
                queue.jobs.append(queued)
                return wake
            }
            if wake {
                event.signal()
            }
        }

        func checkIsolated() {
            precondition(event.isCurrent)
        }

        func isIsolatingCurrentContext() -> Bool? {
            event.isCurrent
        }

        func finish() {
            queue.withLock { $0.isFinishing = true }
            event.signal()
        }

        private static func enter(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
            guard let context = unsafe context else {
                return nil
            }
            let executor = unsafe Unmanaged<Interpreter.Executor>.fromOpaque(context)
                .takeRetainedValue()
            executor.event.bind()
            executor.drain()
            return nil
        }

        private func drain() {
            let executor = unsafe asUnownedSerialExecutor()
            var jobs = [UnownedJob]()
            while true {
                event.wait()
                let finishing = queue.withLock { queue in
                    swap(&jobs, &queue.jobs)
                    return queue.isFinishing
                }
                for job in jobs {
                    unsafe job.runSynchronously(on: executor)
                }
                if finishing {
                    return
                }
                jobs.removeAll(keepingCapacity: true)
            }
        }
    }
}

// MARK: - Interpreter.Executor.Event

private extension Interpreter.Executor {
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

//
//  Created by Anton Spivak
//

internal import libcpython
internal import NIOCore
import Synchronization
internal import SystemPackage

// MARK: - Interpreter.CallbackExecutor

extension Interpreter {
    /// Runs the bodies of asynchronous Swift functions called by Python.
    /// A body can synchronously call back into Python and occupy its thread while
    /// waiting for the session delegate. The dispatcher and delegate run independently.
    final class CallbackExecutor: TaskExecutor {
        private let workers: Workers

        init() throws {
            workers = try Workers()
        }

        deinit { workers.stop() }

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            workers.submit {
                unsafe job.runSynchronously(on: self.asUnownedTaskExecutor())
            }
        }
    }
}

// MARK: - Interpreter.CallbackExecutor.Workers

private extension Interpreter.CallbackExecutor {
    final class Workers: Sendable {
        typealias Work = @Sendable () -> Void

        private struct State {
            var jobs: CircularBuffer<Work> = .init()
            var count = 0
            var busy = 0
        }

        // Two callbacks can make progress independently even on a single-core host.
        private let limit = max(2, System.coreCount)
        private let state: Mutex = .init(State())
        private let ready: PThread.Event

        init() throws {
            ready = try PThread.Event()
            try state.withLock { try startWorker(in: &$0) }
        }

        func submit(_ work: @escaping Work) {
            state.withLock { state in
                state.jobs.append(work)
                if state.jobs.count > state.count - state.busy, state.count < limit {
                    // Existing workers drain the queue if another thread cannot be started.
                    try? startWorker(in: &state)
                }
                // The event coalesces signals. Wake the first worker for a new batch.
                if state.jobs.count == 1 {
                    ready.signal()
                }
            }
        }

        func stop() {
            ready.signal()
        }

        private func startWorker(in state: inout State) throws {
            let context = unsafe Unmanaged.passRetained(self).toOpaque()
            let status = unsafe CPython_StartThread({ pointer in
                unsafe Workers.runThread(pointer)
                return nil
            }, context)
            guard status == 0 else {
                unsafe Unmanaged<Workers>.fromOpaque(context).release()
                throw Errno(rawValue: status)
            }
            state.count += 1
        }

        private static func runThread(_ pointer: UnsafeMutableRawPointer?) {
            guard let pointer = unsafe pointer else {
                return
            }
            let workers = unsafe Unmanaged<Workers>.fromOpaque(pointer).takeRetainedValue()
            workers.run()
        }

        private func run() {
            while true {
                ready.wait()
                let work: Work? = state.withLock { state in
                    guard let work = state.jobs.popFirst() else {
                        // stop() woke us with an empty queue. Wake the next worker to exit.
                        ready.signal()
                        return nil
                    }
                    if !state.jobs.isEmpty {
                        ready.signal()
                    }
                    state.busy += 1
                    return work
                }
                guard let work else {
                    return
                }
                work()
                state.withLock { $0.busy -= 1 }
            }
        }
    }
}

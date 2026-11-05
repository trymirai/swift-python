//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization
internal import SystemPackage

// MARK: - InterpreterExecutor

// Runs Swift actor jobs on the same OS thread for the lifetime of a session.
final class InterpreterExecutor: SerialExecutor {
    private struct Queue {
        var jobs: [UnownedJob] = []
        var isFinishing: Bool = false
    }

    private let queue: Mutex<Queue> = .init(Queue())
    private let event: ThreadEvent

    init() throws {
        self.event = try ThreadEvent()
        let context = unsafe Unmanaged.passRetained(self).toOpaque()
        let status = unsafe CPython_StartThread({ context in
            unsafe InterpreterExecutor.enter(context)
        }, context)
        if status != 0 {
            unsafe Unmanaged<InterpreterExecutor>.fromOpaque(context).release()
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
        let executor = unsafe Unmanaged<InterpreterExecutor>.fromOpaque(context).takeRetainedValue()
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

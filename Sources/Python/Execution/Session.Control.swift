//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

// MARK: - Session.Control

extension Session {
    final class Control: Sendable {
        typealias OutputHandler = @Sendable (Output.Stream, String) -> Void
        typealias InterruptionHandler<Result> = @Sendable (
            Swift::Result<Result, any Swift::Error>,
        ) -> Result

        typealias Settlement<Result> = @Sendable (
            isolated Session,
            Control,
            Swift::Result<Result, any Swift::Error>,
        ) async -> Swift::Result<Result, any Swift::Error>

        private let state: Mutex<State>
        let hasOutputHandler: Bool

        let pipe: Pipe
        let subprocesses: Subprocesses?

        private let incomingCalls: AsyncStream<Invocation>
        private let submissions: AsyncStream<Invocation>.Continuation

        init(
            scope: (any Sendable)? = nil,
            output: OutputHandler? = nil,
            allowsSubprocesses: Bool = false,
        ) throws {
            self.pipe = try Pipe()
            self.subprocesses = allowsSubprocesses ? try Subprocesses() : nil

            self.hasOutputHandler = output != nil
            self.state = .init(State(scope: scope, outputHandler: output))

            (self.incomingCalls, self.submissions) = AsyncStream.makeStream()
        }

        var scope: (any Sendable)? {
            state.withLock { $0.scope }
        }
    }
}

// MARK: Session.Control + Execution lifetime

extension Session.Control {
    func withCancellation<Result>(
        _ operation: () async throws -> Result,
    ) async rethrows -> Result {
        try await withTaskCancellationHandler(
            operation: {
                do {
                    return try await operation()
                } catch {
                    try checkInterruption()
                    throw error
                }
            },
            onCancel: {
                self.requestInterruption()
            },
        )
    }

    func run<Result: Sendable>(
        on session: isolated Session,
        onInterruption: InterruptionHandler<Result>? = nil,
        settling: Settlement<Result>? = nil,
        _ operation: @Sendable (isolated Session) async throws -> Result,
    ) async throws -> Result {
        defer { _ = state.withLock { exchange(&$0.scope, with: nil) } }

        state.withLock { $0.start() }

        // Callbacks and delegates must be able to run while the interpreter thread is occupied.
        return try await withTaskExecutorPreference(globalConcurrentExecutor, isolation: session) {
            try await runOperation(
                on: session,
                onInterruption: onInterruption,
                settling: settling,
                operation,
            )
        }
    }

    private func runOperation<Result: Sendable>(
        on session: isolated Session,
        onInterruption: InterruptionHandler<Result>?,
        settling: Settlement<Result>?,
        _ operation: @Sendable (isolated Session) async throws -> Result,
    ) async throws -> Result {
        try await withCancellation {
            // Control publishes interruption and wakes Python before cancelling its callbacks.
            // Join the dispatcher here so implicit child cancellation cannot reorder those events.
            let callbacks = Task { await self.runCalls() }

            var result = await operationResult(on: session, operation)

            // Every native access must detach before publication or close.
            await finishAccesses()
            if settling != nil || subprocesses != nil {
                settleCallsAndSubprocesses(on: session, result: &result)
            }

            if let settling {
                await callbacks.value
                result = await settling(session, self, result)
            }

            let wasInterrupted = finish()
            // Python can return before interrupted Swift callbacks finish their cleanup.
            await callbacks.value
            return try completedResult(result, interrupted: wasInterrupted, using: onInterruption)
        }
    }

    private func completedResult<Result>(
        _ result: Swift::Result<Result, any Swift::Error>,
        interrupted: Bool,
        using onInterruption: InterruptionHandler<Result>?,
    ) throws -> Result {
        guard interrupted else {
            return try result.get()
        }
        guard let onInterruption else {
            throw CancellationError()
        }
        return onInterruption(result)
    }

    private func operationResult<Result: Sendable>(
        on session: isolated Session,
        _ operation: @Sendable (isolated Session) async throws -> Result,
    ) async -> Swift::Result<Result, any Swift::Error> {
        do {
            try checkInterruption()
            return .success(try await operation(session))
        } catch {
            return .failure(error)
        }
    }

    private func settleCallsAndSubprocesses<Result>(
        on session: isolated Session,
        result: inout Swift::Result<Result, any Swift::Error>,
    ) {
        if let subprocesses, case .success = result, session.hasOpenPipes(in: subprocesses) {
            let failure = Failure(
                "Python returned with a running subprocess and an open PIPE. "
                    + "Call communicate() or redirect the stream to a file.",
            )
            result = .failure(failure)
        }
        if case .failure = result {
            subprocesses?.stop()
        }

        finishCalls(state.withLock { $0.settleCalls() })

        // The executor owns the wait. Cancellation can still signal children.
        do {
            try subprocesses?.join()
        } catch {
            if case .success = result {
                result = .failure(error)
            }
        }
    }
}

// MARK: Session.Control + Native access

extension Session.Control {
    func withAccess<Result: ~Copyable>(_ body: () throws -> Result) throws -> Result {
        try checkInterruption()
        try state.withLock { try $0.beginAccess() }
        defer {
            let completion = state.withLock { $0.endAccess() }
            completion?.resume()
        }
        return try body()
    }

    private func finishAccesses() async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { $0.finishAccesses(continuation) }
            if finished {
                continuation.resume()
            }
        }
    }
}

// MARK: Session.Control + Callback dispatch

extension Session.Control {
    @concurrent
    private func runCalls() async {
        await withDiscardingTaskGroup { group in
            for await call in incomingCalls {
                guard state.withLock({ $0.phase.isRunning }) else {
                    break
                }
                let admitted = group.addTaskUnlessCancelled { await call.run() }
                guard admitted else {
                    break
                }
            }
            group.cancelAll()
        }
    }

    func submit(_ call: Invocation, id: CallID) throws {
        try checkInterruption()
        try state.withLock { try $0.admit(call, id: id) }

        guard case .enqueued = submissions.yield(call) else {
            cancelCall(id)
            try checkInterruption()
            throw Failure("The Python execution has stopped accepting Swift calls.")
        }
    }

    func cancelCall(_ id: CallID) {
        state.withLock { $0.calls.removeValue(forKey: id) }?.cancel()
    }

    func cancelExport(_ id: CallID) {
        let call = state.withLock { state -> Invocation? in
            guard case .export? = state.calls[id] else {
                return nil
            }
            return state.calls.removeValue(forKey: id)
        }
        call?.cancel()
    }

    func export(_ id: CallID) throws -> ExportCall {
        guard case let .export(call)? = state.withLock({ $0.calls[id] }) else {
            throw Failure("Unknown Swift callback.")
        }
        return call
    }

    func takeExport(_ id: CallID) throws -> any Encodable & Sendable {
        let call = try export(id)
        guard let outcome = call.take() else {
            throw Failure("The Swift callback has not completed.")
        }
        defer { cancelCall(id) }
        return try outcome.get()
    }
}

// MARK: Session.Control + Interruption and settlement

extension Session.Control {
    func beginEvaluation(in interpreter: UInt) {
        let thread = unsafe UInt(bitPattern: PyThreadState_Get())
        state.withLock { $0.evaluations.begin(in: interpreter, on: thread) }
    }

    func endEvaluation() {
        let thread = unsafe UInt(bitPattern: PyThreadState_Get())
        state.withLock { $0.evaluations.end(on: thread, interrupted: $0.phase.isInterrupted) }
    }

    func requestInterruption() {
        guard let calls = state.withLock({ $0.interrupt() }) else {
            return
        }

        subprocesses?.stop()
        pipe.signal()
        finishCalls(calls)
    }

    func deliverInterruption() -> Bool {
        let current = unsafe UInt(bitPattern: PyThreadState_Get())
        return state.withLock { state in
            state.phase.isInterrupted && state.evaluations.markInterrupted(on: current)
        }
    }

    private func finishCalls(_ calls: [CallID: Invocation]) {
        submissions.finish()
        for call in calls.values {
            call.cancel()
        }
    }

    func finish() -> Bool {
        let (wasInterrupted, calls) = state.withLock { $0.finish() }
        if let calls {
            finishCalls(calls)
            pipe.close()
        }
        return wasInterrupted
    }

    func finishCheckingInterruption() throws {
        if finish() {
            throw CancellationError()
        }
    }

    var isInterrupted: Bool {
        state.withLock { $0.phase.isInterrupted }
    }

    func checkInterruption() throws {
        if isInterrupted {
            throw CancellationError()
        }
    }

    func write(_ stream: Output.Stream, _ text: String) {
        let outputHandler = state.withLock { $0.outputHandler }
        outputHandler?(stream, text)
    }
}

// MARK: - Session.Control.State

private extension Session.Control {
    struct State {
        var phase: Phase = .ready
        var evaluations: Evaluations = .init()

        var calls: [CallID: Invocation] = [:]

        var activeAccesses: Int = 0
        var accessesClosed: Bool = false
        var accessCompletion: CheckedContinuation<Void, Never>?

        var scope: (any Sendable)?
        var outputHandler: OutputHandler?

        mutating func start() {
            if case .ready = phase {
                phase = .running
            }
        }

        mutating func beginAccess() throws {
            guard phase.isRunning, !accessesClosed else {
                throw Failure.closed
            }
            activeAccesses += 1
        }

        mutating func endAccess() -> CheckedContinuation<Void, Never>? {
            activeAccesses -= 1
            return activeAccesses == 0 ? exchange(&accessCompletion, with: nil) : nil
        }

        mutating func finishAccesses(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            accessesClosed = true
            guard activeAccesses != 0 else {
                return true
            }
            accessCompletion = continuation
            return false
        }

        mutating func admit(_ call: Invocation, id: CallID) throws {
            if phase.isInterrupted {
                throw CancellationError()
            }
            guard phase.isRunning else {
                throw Failure("Swift callbacks require an active Python execution.")
            }
            calls[id] = call
        }

        mutating func interrupt() -> [CallID: Invocation]? {
            switch phase {
            case .ready, .running, .settling:
                phase = .interrupted
                evaluations.requestInterrupt()
                return calls
            case .interrupted, .finished:
                return nil
            }
        }

        mutating func settleCalls() -> [CallID: Invocation] {
            if case .running = phase {
                phase = .settling
            }
            return exchange(&calls, with: [:])
        }

        // Only the first caller takes the calls and closes their pipe.
        mutating func finish() -> (wasInterrupted: Bool, calls: [CallID: Invocation]?) {
            if case let .finished(wasInterrupted) = phase {
                return (wasInterrupted, nil)
            }

            let wasInterrupted = phase.isInterrupted
            phase = .finished(wasInterrupted: wasInterrupted)
            outputHandler = nil
            return (wasInterrupted, exchange(&calls, with: [:]))
        }
    }
}

// MARK: - Session.Control.Evaluations

private extension Session.Control {
    struct Evaluations {
        private struct Thread {
            var depth: Int = 0
            var interrupted: Bool = false
        }

        private var interpreter: UInt?
        private var threads: [UInt: Thread] = [:]

        mutating func begin(in interpreter: UInt, on thread: UInt) {
            precondition(self.interpreter == nil || self.interpreter == interpreter)
            self.interpreter = interpreter
            threads[thread, default: .init()].depth += 1
        }

        mutating func end(on thread: UInt, interrupted: Bool) {
            threads[thread]!.depth -= 1
            if threads[thread]!.depth == 0 {
                threads.removeValue(forKey: thread)
            }

            if threads.isEmpty {
                interpreter = nil
            } else if interrupted {
                requestInterrupt()
            }
        }

        func requestInterrupt() {
            // The state lock prevents the final evaluation from clearing the interpreter here.
            if let interpreter, let pointer = unsafe OpaquePointer(bitPattern: interpreter) {
                unsafe CPython_RequestEvaluationInterrupt(pointer)
            }
        }

        mutating func markInterrupted(on thread: UInt) -> Bool {
            let shouldDeliver = threads[thread]?.interrupted == false
            if shouldDeliver {
                threads[thread]?.interrupted = true
            }
            // Each attachment delivers on its own thread so its loop can unwind safely.
            if threads.values.contains(where: { !$0.interrupted }) {
                requestInterrupt()
            }
            return shouldDeliver
        }
    }
}

// MARK: - Session.Control.Phase

private extension Session.Control {
    enum Phase {
        case ready
        case running
        case settling
        case interrupted
        case finished(wasInterrupted: Bool)

        var isRunning: Bool {
            if case .running = self {
                true
            } else {
                false
            }
        }

        var isInterrupted: Bool {
            switch self {
            case .interrupted:
                true
            case let .finished(interrupted):
                interrupted
            case .ready, .running, .settling:
                false
            }
        }
    }
}

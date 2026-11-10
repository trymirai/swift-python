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
            Interruption,
            Swift::Result<Result, any Swift::Error>,
        ) -> Result

        typealias Settlement<Result> = @Sendable (
            isolated Session,
            Control,
            Swift::Result<Result, any Swift::Error>,
        ) async -> Swift::Result<Result, any Swift::Error>

        @TaskLocal
        static var sessionPath: [ObjectIdentifier] = []

        enum Interruption: Sendable {
            case stopped
            case timedOut
        }

        let hasOutputHandler: Bool
        private let timeout: Duration?

        private let state: Mutex<State>

        let pipe: Pipe
        let subprocesses: Subprocesses?

        private let incomingCalls: AsyncStream<Invocation>
        private let submissions: AsyncStream<Invocation>.Continuation

        init(
            timeout: Duration?,
            scope: (any Sendable)? = nil,
            output: OutputHandler? = nil,
            allowsSubprocesses: Bool = false,
        ) throws {
            try Self.validateTimeout(timeout)
            self.pipe = try Pipe()
            self.subprocesses = allowsSubprocesses ? try Subprocesses() : nil

            self.hasOutputHandler = output != nil
            self.timeout = timeout

            self.state = .init(State(scope: scope, outputHandler: output))

            (self.incomingCalls, self.submissions) = AsyncStream.makeStream()
        }

        var scope: (any Sendable)? {
            state.withLock { $0.scope }
        }

        static func validateTimeout(_ timeout: Duration?) throws {
            if let timeout, timeout <= .zero {
                throw Runtime.Failure("Expected a positive Python execution timeout.")
            }
        }

        func withCancellation<Result>(
            _ operation: () async throws -> Result,
        ) async rethrows -> Result {
            try await withTaskCancellationHandler {
                do {
                    return try await operation()
                } catch {
                    try checkInterruption()
                    throw error
                }
            } onCancel: {
                self.requestInterruption(.stopped)
            }
        }

        func run<Result>(
            on session: isolated Session,
            onInterruption: InterruptionHandler<Result>? = nil,
            settling: Settlement<Result>? = nil,
            _ operation: (isolated Session) async throws -> Result,
        ) async throws -> Result {
            defer { _ = state.withLock { exchange(&$0.scope, with: nil) } }

            let deadline = timeout.map { ContinuousClock.now + $0 }
            state.withLock { $0.start(until: deadline) }

            async let callbacks: Void = runCalls()
            async let _: Void = watchDeadline(deadline)

            var result: Swift::Result<Result, any Swift::Error>
            do {
                try checkInterruption()
                result = .success(try await operation(session))
            } catch {
                result = .failure(error)
            }

            if settling != nil || subprocesses != nil {
                settleCallsAndSubprocesses(on: session, result: &result)
            }

            if let settling {
                await callbacks
                result = await settling(session, self, result)
            }

            let interruption = finish()
            // Python can return before interrupted Swift callbacks finish their cleanup.
            await callbacks

            guard let interruption else {
                return try result.get()
            }
            guard let onInterruption else {
                throw CancellationError()
            }
            return onInterruption(interruption, result)
        }

        private func settleCallsAndSubprocesses<Result>(
            on session: isolated Session,
            result: inout Swift::Result<Result, any Swift::Error>,
        ) {
            if let subprocesses, case .success = result, session.hasOpenPipes(in: subprocesses) {
                result = .failure(Runtime.Failure(
                    "Python returned with a running subprocess and an open PIPE. "
                        + "Call communicate() or redirect the stream to a file.",
                ))
            }
            if case .failure = result {
                subprocesses?.stop()
            }

            finishCalls(state.withLock { $0.settleCalls() })

            // The executor owns the wait. The deadline task and Stop can still signal children.
            do {
                try subprocesses?.join()
            } catch {
                if case .success = result {
                    result = .failure(error)
                }
            }
        }

        @concurrent
        private func watchDeadline(_ deadline: ContinuousClock.Instant?) async {
            guard let deadline else {
                return
            }
            do {
                try await ContinuousClock().sleep(until: deadline)
                requestInterruption(.timedOut)
            } catch {}
        }

        // MARK: Callback dispatch

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
                throw Runtime.Failure("The Python execution has stopped accepting Swift calls.")
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

        func takeExport(_ id: CallID) throws -> any Encodable & Sendable {
            guard case let .export(call)? = state.withLock({ $0.calls[id] }) else {
                throw Runtime.Failure("Unknown Swift callback.")
            }
            guard let outcome = call.take() else {
                throw Runtime.Failure("The Swift callback has not completed.")
            }
            defer { cancelCall(id) }
            return try outcome.get()
        }

        // MARK: Interruption and settlement

        func beginEvaluation(in interpreter: UInt) {
            state.withLock { $0.evaluatingInterpreter = interpreter }
        }

        func endEvaluation() {
            state.withLock { $0.evaluatingInterpreter = nil }
        }

        @discardableResult
        func requestInterruption(_ reason: Interruption) -> Bool {
            interrupt(reason).changed
        }

        func deliverInterruption() -> Bool {
            _ = interrupt()
            return state.withLock { $0.markInterruptionDelivered() }
        }

        private func interrupt(_ requested: Interruption? = nil) -> (
            reason: Interruption?,
            changed: Bool,
        ) {
            let (reason, calls) = state.withLock { state in
                let transition = state.interrupt(requested)
                if requested != nil, transition.calls != nil {
                    state.requestEvaluationInterrupt()
                }
                return transition
            }

            if let calls {
                subprocesses?.stop()
                pipe.signal()
                finishCalls(calls)
            }
            return (reason, calls != nil)
        }

        private func finishCalls(_ calls: [CallID: Invocation]) {
            submissions.finish()
            for call in calls.values {
                call.cancel()
            }
        }

        func finish() -> Interruption? {
            let (interruption, calls) = state.withLock { $0.finish() }
            if let calls {
                finishCalls(calls)
                pipe.close()
            }
            return interruption
        }

        func finishCheckingInterruption() throws {
            if finish() != nil {
                throw CancellationError()
            }
        }

        var interruption: Interruption? {
            interrupt().reason
        }

        func checkInterruption() throws {
            if interruption != nil {
                throw CancellationError()
            }
        }

        func write(_ stream: Output.Stream, _ text: String) {
            let outputHandler = state.withLock { $0.outputHandler }
            outputHandler?(stream, text)
        }
    }
}

// MARK: - Session.Control.State

private extension Session.Control {
    struct State {
        // A call snapshot tells the caller to close admission for this transition.
        typealias Transition = (reason: Interruption?, calls: [CallID: Invocation]?)

        var phase: Phase = .ready
        var evaluatingInterpreter: UInt?
        var calls: [CallID: Invocation] = [:]

        var scope: (any Sendable)?
        var outputHandler: OutputHandler?

        mutating func start(until deadline: ContinuousClock.Instant?) {
            if case .ready = phase {
                phase = .running(deadline)
            }
        }

        mutating func admit(_ call: Invocation, id: CallID) throws {
            if phase.interruption != nil {
                throw CancellationError()
            }
            guard phase.isRunning else {
                throw Runtime.Failure("Swift callbacks require an active Python execution.")
            }
            calls[id] = call
        }

        mutating func interrupt(_ requested: Interruption?) -> Transition {
            switch phase {
            case .ready, .running, .settling:
                guard let reason = phase.expiration ?? requested else {
                    return (nil, nil)
                }
                phase = .interrupted(reason, delivered: false)
                return (reason, calls)
            case .interrupted, .finished:
                return (phase.interruption, nil)
            }
        }

        func requestEvaluationInterrupt() {
            // The state lock keeps endEvaluation from clearing this pointer during the call.
            if
                let key = evaluatingInterpreter,
                let interpreter = unsafe OpaquePointer(bitPattern: key)
            {
                unsafe CPython_RequestEvaluationInterrupt(interpreter)
            }
        }

        mutating func markInterruptionDelivered() -> Bool {
            guard case let .interrupted(reason, false) = phase else {
                return false
            }
            phase = .interrupted(reason, delivered: true)
            return true
        }

        mutating func settleCalls() -> [CallID: Invocation] {
            if case let .running(deadline) = phase {
                phase = .settling(deadline)
            }
            return exchange(&calls, with: [:])
        }

        mutating func finish() -> Transition {
            if case let .finished(interruption) = phase {
                return (interruption, nil)
            }
            let interruption = phase.interruption ?? phase.expiration
            phase = .finished(interruption)
            outputHandler = nil
            return (interruption, exchange(&calls, with: [:]))
        }
    }
}

// MARK: - Session.Control.Phase

private extension Session.Control {
    enum Phase {
        case ready
        case running(ContinuousClock.Instant?)
        case settling(ContinuousClock.Instant?)
        case interrupted(Interruption, delivered: Bool)
        case finished(Interruption?)

        var isRunning: Bool {
            if case .running = self {
                true
            } else {
                false
            }
        }

        var interruption: Interruption? {
            switch self {
            case let .interrupted(reason, _):
                reason
            case let .finished(reason):
                reason
            case .ready, .running, .settling:
                nil
            }
        }

        var expiration: Interruption? {
            switch self {
            case let .running(deadline?), let .settling(deadline?):
                ContinuousClock.now >= deadline ? .timedOut : nil
            default:
                nil
            }
        }
    }
}

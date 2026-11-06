//
//  Created by Anton Spivak
//

import Synchronization
internal import SystemPackage

// MARK: - Session.Control

extension Session {
    final class Control: Sendable {
        typealias OutputHandler = @Sendable (Output.Stream, String) -> Void
        typealias InterruptionHandler<Result> = @Sendable (
            Interruption,
            Swift::Result<Result, any Swift::Error>,
        ) -> Result

        @TaskLocal
        static var sessionPath: [ObjectIdentifier] = []

        enum Interruption: Sendable {
            case stopped
            case timedOut
        }

        let hasOutputHandler: Bool
        let redirects: Stream.Redirects
        private let timeout: Duration?

        let pipe: Pipe
        private let state: Mutex<State>

        private let incomingCalls: AsyncStream<Invocation>
        private let submissions: AsyncStream<Invocation>.Continuation

        init(
            timeout: Duration?,
            output: OutputHandler? = nil,
            redirecting redirects: [Stream: FilePath] = [:],
        ) throws {
            try Self.validateTimeout(timeout)
            self.redirects = try Stream.Redirects(redirects)
            self.pipe = try Pipe()

            self.hasOutputHandler = output != nil
            self.timeout = timeout

            self.state = .init(State(outputHandler: output))
            (self.incomingCalls, self.submissions) = AsyncStream.makeStream()
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
            _ operation: (isolated Session) async throws -> Result,
        ) async throws -> Result {
            let deadline = timeout.map { ContinuousClock.now + $0 }
            state.withLock { $0.start(until: deadline) }

            async let callbacks: Void = runCalls(until: deadline)

            let result: Swift::Result<Result, any Swift::Error>
            do {
                try checkInterruption()
                result = .success(try await operation(session))
            } catch {
                result = .failure(error)
            }

            // Close callback admission, then join the already admitted calls.
            let interruption = finish()
            await callbacks

            if let interruption {
                guard let onInterruption else {
                    throw CancellationError()
                }
                return onInterruption(interruption, result)
            }
            return try result.get()
        }

        @concurrent
        private func runCalls(until deadline: ContinuousClock.Instant?) async {
            await withDiscardingTaskGroup { group in
                if let deadline {
                    group.addTask {
                        do {
                            try await ContinuousClock().sleep(until: deadline)
                            self.requestInterruption(.timedOut)
                        } catch {}
                    }
                }

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
            let (reason, calls) = state.withLock { $0.interrupt(requested) }
            if let calls {
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
        // A snapshot is present only when the transition changes the phase.
        typealias Transition = (reason: Interruption?, calls: [CallID: Invocation]?)

        var phase: Phase = .ready
        var outputHandler: OutputHandler?

        var calls: [CallID: Invocation] = [:]

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
            case .ready, .running:
                guard let reason = phase.expiration ?? requested else {
                    return (nil, nil)
                }
                phase = .interrupted(reason, delivered: false)
                return (reason, calls)
            case .interrupted, .finished:
                return (phase.interruption, nil)
            }
        }

        mutating func markInterruptionDelivered() -> Bool {
            guard case let .interrupted(reason, false) = phase else {
                return false
            }
            phase = .interrupted(reason, delivered: true)
            return true
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
            case .ready, .running:
                nil
            }
        }

        var expiration: Interruption? {
            if case let .running(deadline?) = self, .now >= deadline {
                .timedOut
            } else {
                nil
            }
        }
    }
}

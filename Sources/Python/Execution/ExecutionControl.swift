//
//  Created by Anton Spivak
//

import Synchronization

// MARK: - ExecutionControl

final class ExecutionControl: Sendable {
    typealias OutputHandler = @Sendable (Output.Stream, String) -> Void

    enum Interruption: Sendable {
        case stopped
        case timedOut

        func error(with output: Output = .empty) -> ExecutionError {
            switch self {
            case .stopped:
                .stopped(output)
            case .timedOut:
                .timedOut(output)
            }
        }
    }

    private struct State {
        var deadline: ContinuousClock.Instant?
        var interruption: Interruption?
        var isInterruptionDelivered: Bool = false
        var isFinished: Bool = false
        var outputHandler: OutputHandler?

        mutating func expireIfNeeded(at now: ContinuousClock.Instant) {
            if interruption == nil, let deadline, now >= deadline {
                interruption = .timedOut
            }
        }
    }

    let pipe: WakeupPipe
    let hasOutputHandler: Bool
    let standardIO: StandardIO
    private let timeout: Duration?
    private let state: Mutex<State>

    init(timeout: Duration?, onOutput: OutputHandler?, standardIO: StandardIO = .init()) throws {
        try Self.validateTimeout(timeout)
        self.pipe = try WakeupPipe()
        self.hasOutputHandler = onOutput != nil
        self.standardIO = standardIO
        self.timeout = timeout
        self.state = .init(State(outputHandler: onOutput))
    }

    static func validateTimeout(_ timeout: Duration?) throws {
        if let timeout, timeout <= .zero {
            throw RuntimeFailure("Expected a positive Python execution timeout.")
        }
    }

    func withCancellation<Result>(_ operation: () async throws -> Result) async rethrows -> Result {
        try await withTaskCancellationHandler(operation: operation) {
            self.requestInterruption(.stopped)
        }
    }

    func startTimeoutTask() -> Task<Void, Never>? {
        guard let timeout else {
            return nil
        }
        let deadline = ContinuousClock.now + timeout
        state.withLock { $0.deadline = deadline }
        return Task.detached { [self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
                requestInterruption(.timedOut)
            } catch {}
        }
    }

    @discardableResult
    func requestInterruption(_ reason: Interruption) -> Bool {
        let didRequestInterruption = state.withLock { state in
            guard !state.isFinished, state.interruption == nil else {
                return false
            }
            state.expireIfNeeded(at: .now)
            if state.interruption == nil {
                state.interruption = reason
            }
            return true
        }
        if didRequestInterruption {
            pipe.signal()
        }
        return didRequestInterruption
    }

    func deliverInterruption() -> Bool {
        state.withLock { state in
            guard !state.isFinished, !state.isInterruptionDelivered else {
                return false
            }
            if state.deadline != nil {
                state.expireIfNeeded(at: .now)
            }
            guard state.interruption != nil else {
                return false
            }
            state.isInterruptionDelivered = true
            return true
        }
    }

    func finish() -> Interruption? {
        let interruption = state.withLock { state in
            if state.isFinished {
                return state.interruption
            }
            state.expireIfNeeded(at: .now)
            state.isFinished = true
            state.outputHandler = nil
            return state.interruption
        }
        pipe.close()
        return interruption
    }

    func finishCheckingInterruption() throws {
        if let interruption = finish() {
            throw interruption.error()
        }
    }

    func checkInterruption() throws {
        let interruption = state.withLock { state in
            state.expireIfNeeded(at: .now)
            return state.interruption
        }
        if let interruption {
            throw interruption.error()
        }
    }

    func write(_ stream: Output.Stream, _ text: String) {
        let outputHandler = state.withLock { $0.outputHandler }
        outputHandler?(stream, text)
    }
}

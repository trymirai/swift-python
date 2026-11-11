//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization
internal import SystemPackage

// MARK: - Session.Control.Call

extension Session.Control {
    typealias ExportCall = Call<any Encodable & Sendable>

    final class Call<Reply: Sendable>: Sendable {
        typealias Outcome = Swift::Result<Reply, any Swift::Error>

        private let operation: @Sendable () async throws -> Reply
        private let context: Context?

        private let state: Mutex<State>

        let pipe: Pipe

        init(
            _ operation: @escaping @Sendable () async throws -> Reply,
            context: Context? = nil,
        ) throws {
            self.pipe = try Pipe()

            self.operation = operation
            self.context = context
            self.state = .init(State(streams: context?.streams))
        }

        func run() async {
            await withTaskCancellationHandler {
                await withDiscardingTaskGroup { group in
                    group.addTask { await self.invoke() }

                    await waitForCompletion()
                    cancel()
                    group.cancelAll()
                }
            } onCancel: {
                self.cancel()
            }
        }

        private func waitForCompletion() async {
            await withCheckedContinuation { continuation in
                let finished = state.withLock { $0.waitForCompletion(continuation) }
                if finished {
                    continuation.resume()
                }
            }
        }

        private func invoke() async {
            guard state.withLock({ $0.phase.isPending }) else {
                return
            }

            do {
                try Task.checkCancellation()
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }

        func take() -> Outcome? {
            state.withLock { $0.take() }
        }

        func withContext<Result: ~Copyable>(
            _ body: (borrowing Context) throws -> Result,
        ) throws -> Result {
            try checkActive()
            guard let context else {
                throw Session.Error.closed
            }
            return try context.withAccess(body)
        }

        func checkActive() throws {
            guard state.withLock({ $0.phase.isPending }) else {
                throw Session.Error.closed
            }
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }

        private func finish(_ outcome: Outcome) {
            guard let pendingMethods = state.withLock({ $0.finish(outcome) }) else {
                return
            }
            signalCompletion()
            pendingMethods.forEach { $0.cancel() }
        }

        private func signalCompletion() {
            let (continuation, streams) = state.withLock {
                (exchange(&$0.completion, with: nil), exchange(&$0.streams, with: nil))
            }
            pipe.signal()
            continuation?.resume()
            withExtendedLifetime(streams) {}
        }

        func submit(_ method: any ImportedMethodRequest) throws {
            try state.withLock { state in
                guard state.phase.isPending else {
                    throw CancellationError()
                }

                // Polling takes the same lock, so a failed write can leave the queue intact.
                try notify(&state)
                state.methods.append(method)
            }
        }

        func wake() {
            try? state.withLock { state in
                if state.phase.isPending {
                    try notify(&state)
                }
            }
        }

        func poll() throws -> [any ImportedMethodRequest]? {
            try state.withLock { state in
                if state.notified {
                    try pipe.consumeNotification()
                    state.notified = false
                }

                guard state.phase.isPending else {
                    return nil
                }
                return exchange(&state.methods, with: [])
            }
        }

        private func notify(_ state: inout State) throws {
            // One unread byte is enough for the loop to drain all pending work.
            if !state.notified {
                try pipe.notify()
                state.notified = true
            }
        }
    }
}

// MARK: - Session.Control.Call.Phase

extension Session.Control.Call {
    private enum Phase {
        case pending
        case ready(Outcome)
        case taken

        var isPending: Bool {
            if case .pending = self {
                true
            } else {
                false
            }
        }
    }
}

// MARK: - Session.Control.Call.State

extension Session.Control.Call {
    private struct State {
        var phase: Phase = .pending

        var methods: [any ImportedMethodRequest] = []
        var notified: Bool = false

        var completion: CheckedContinuation<Void, Never>?
        var streams: Session.Stream.Descriptors?

        mutating func waitForCompletion(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            guard phase.isPending else {
                return true
            }
            completion = continuation
            return false
        }

        mutating func take() -> Outcome? {
            guard case let .ready(outcome) = phase else {
                return nil
            }
            phase = .taken
            return outcome
        }

        mutating func finish(_ outcome: Outcome) -> [any ImportedMethodRequest]? {
            guard phase.isPending else {
                return nil
            }
            phase = .ready(outcome)
            return exchange(&methods, with: [])
        }
    }
}

// MARK: - Session.Control.CallID

extension Session.Control {
    struct CallID: Hashable, Sendable {
        let rawValue: Int
    }
}

// MARK: - Session.Control.Invocation

extension Session.Control {
    enum Invocation: Sendable {
        case export(ExportCall)
        case fileAccess(Call<Bool>)

        func run() async {
            switch self {
            case let .export(call):
                await CurrentContext.withExport(call) { await call.run() }
            case let .fileAccess(call):
                await CurrentContext.withExport(nil) { await call.run() }
            }
        }

        func cancel() {
            switch self {
            case let .export(call):
                call.cancel()
            case let .fileAccess(call):
                call.cancel()
            }
        }
    }
}

extension Session.Control {
    /// Waits on the interpreter thread without its Python thread state attached.
    func waitForFileAccess(_ call: Call<Bool>, id: CallID) throws -> Bool {
        try submit(.fileAccess(call), id: id)
        defer { cancelCall(id) }

        let status = try CPython_WaitForCall(
            call.pipe.readDescriptor().rawValue,
            pipe.readDescriptor().rawValue,
        )

        try checkInterruption()
        guard status == 0 else {
            throw Errno(rawValue: status)
        }
        guard let outcome = call.take() else {
            throw Runtime.Failure("The file access decision has not completed.")
        }
        return try outcome.get()
    }
}

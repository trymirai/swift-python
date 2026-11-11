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
        private let origin: [ObjectIdentifier]

        private let state: Mutex<State> = .init(State())
        let pipe: Pipe

        private let completion: AsyncStream<Void>
        private let completionSignal: AsyncStream<Void>.Continuation

        init(
            _ operation: @escaping @Sendable () async throws -> Reply,
            sessionID: ObjectIdentifier?,
        ) throws {
            var origin = Session.Control.sessionPath
            if let sessionID {
                origin.append(sessionID)
            }

            self.pipe = try Pipe()

            self.operation = operation
            self.origin = origin

            (self.completion, self.completionSignal) = AsyncStream.makeStream()
        }

        func run() async {
            await withDiscardingTaskGroup { group in
                group.addTask { await self.invoke() }

                // Either completion or cancellation closes this stream.
                for await _ in completion {}

                cancel()
                group.cancelAll()
            }
        }

        private func invoke() async {
            guard state.withLock({ $0.phase.isPending }) else {
                return
            }

            await Session.Control.$sessionPath.withValue(origin) {
                do {
                    try Task.checkCancellation()
                    finish(.success(try await operation()))
                } catch {
                    finish(.failure(error))
                }
            }
        }

        func take() -> Outcome? {
            state.withLock { $0.take() }
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }

        private func finish(_ outcome: Outcome) {
            let pendingMethods = state.withLock { $0.finish(outcome) }
            guard let pendingMethods else {
                return
            }

            pipe.signal()
            completionSignal.finish()
            pendingMethods.forEach { $0.cancel() }
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
                guard state.phase.isPending else {
                    return nil
                }

                if state.notified {
                    try pipe.consumeNotification()
                    state.notified = false
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
        var notified = false

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
                await Session.Control.$currentExport.withValue(call) { await call.run() }
            case let .fileAccess(call):
                await Session.Control.$currentExport.withValue(nil) { await call.run() }
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

//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization
internal import SystemPackage

// MARK: - Session.Control.Call

extension Session.Control {
    final class Call<Reply: Sendable>: Sendable {
        typealias Outcome = Swift::Result<Reply, any Swift::Error>

        private enum State {
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

        private let operation: @Sendable () async throws -> Reply
        private let origin: [ObjectIdentifier]

        private let state: Mutex<State> = .init(.pending)

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
                // Closing the stream wakes this task when Python cancels this call.
                for await _ in completion {}
                cancel()
                group.cancelAll()
            }
        }

        private func invoke() async {
            guard state.withLock({ $0.isPending }) else {
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
            state.withLock { state in
                guard case let .ready(outcome) = state else {
                    return nil
                }
                state = .taken
                return outcome
            }
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }

        private func finish(_ outcome: Outcome) {
            let didFinish = state.withLock { state in
                guard state.isPending else {
                    return false
                }
                state = .ready(outcome)
                return true
            }

            if didFinish {
                pipe.signal()
                completionSignal.finish()
            }
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
        case export(Call<any Encodable & Sendable>)
        case fileOpen(Call<Bool>)

        func run() async {
            switch self {
            case let .export(call):
                await call.run()
            case let .fileOpen(call):
                await call.run()
            }
        }

        func cancel() {
            switch self {
            case let .export(call):
                call.cancel()
            case let .fileOpen(call):
                call.cancel()
            }
        }
    }
}

extension Session.Control {
    /// Waits on the interpreter thread without its Python thread state attached.
    func waitForFileOpen(_ call: Call<Bool>, id: CallID) throws -> Bool {
        try submit(.fileOpen(call), id: id)
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
            throw Runtime.Failure("The file open decision has not completed.")
        }
        return try outcome.get()
    }
}

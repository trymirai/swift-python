//
//  Created by Anton Spivak
//

import Synchronization

// Owns one asynchronous callback task and completion signal, without borrowed Python state.
final class AsyncCall: Sendable {
    private struct State {
        var result: Swift.Result<CallbackResult, any Swift.Error>?
        var task: Task<Void, Never>?
    }

    let pipe: WakeupPipe
    private let state: Mutex<State> = .init(State())

    convenience init<Value: Encodable & Sendable>(
        _ body: @escaping @Sendable () async throws -> Value,
    ) throws {
        try self.init(result: { CallbackResult(try await body()) })
    }

    convenience init(operation: @escaping Module.Function.AsyncOperation) throws {
        try self.init(result: { CallbackResult(try await operation()) })
    }

    private init(result body: @escaping @Sendable () async throws -> CallbackResult) throws {
        pipe = try WakeupPipe()
        var origin = CallbackOrigin.current
        if let session = InterpreterStorage.current()?.sessionOrigin {
            origin.append(session)
        }
        let task = Task.detached { [self, origin] in
            await CallbackOrigin.$current.withValue(origin) {
                let result: Swift.Result<CallbackResult, any Swift.Error>
                do {
                    result = .success(try await body())
                } catch {
                    result = .failure(error)
                }
                state.withLock { state in
                    state.result = result
                    state.task = nil
                }
                pipe.signal()
            }
        }
        state.withLock { state in
            // Completion may precede publication of the task handle.
            if state.result == nil {
                state.task = task
            }
        }
    }

    func encode(to encoder: inout Encoder) throws {
        guard let result = state.withLock({ $0.result }) else {
            throw RuntimeFailure("A Swift callback has not completed.")
        }
        try result.get().encode(&encoder)
    }

    func cancel() {
        let task = state.withLock { state in
            defer {
                state.task = nil
            }
            return state.task
        }
        task?.cancel()
        pipe.close()
    }
}

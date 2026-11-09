//
//  Created by Anton Spivak
//

import Synchronization

// MARK: - Session.Operations

extension Session {
    // Admission is independent of the executor. The interpreter thread can be
    // blocked waiting for a Swift callback while that callback tries to enter.
    final class Operations: Sendable {
        private let state: Mutex<State> = .init(State())

        func withReservation<Result>(
            _ admission: Admission,
            _ body: () async throws -> Result,
        ) async throws -> Result {
            try Task.checkCancellation()
            switch admission {
            case .queued:
                try await waitForTurn()
            case .immediate:
                guard state.withLock({ $0.reserve() }) else {
                    throw Session.Error.busy
                }
            }
            defer { release() }

            try Task.checkCancellation()
            return try await body()
        }

        func drain(_ body: () async -> Void) async {
            await withCheckedContinuation { continuation in
                let admitted = state.withLock { $0.enqueue(.closing(continuation)) }
                if admitted {
                    continuation.resume()
                }
            }
            defer { release() }
            await body()
        }

        private func waitForTurn() async throws {
            let ticket = Ticket()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result = state.withLock { state -> Swift::Result<Void, any Swift::Error>? in
                        // Check under the same lock used by the cancellation handler.
                        if Task.isCancelled {
                            return .failure(CancellationError())
                        }
                        return state.enqueue(.operation(ticket, continuation)) ? .success(()) : nil
                    }
                    if let result {
                        continuation.resume(with: result)
                    }
                }
            } onCancel: {
                let continuation = state.withLock { $0.removeOperation(ticket) }
                continuation?.resume(throwing: CancellationError())
            }
        }

        private func release() {
            state.withLock { $0.advance() }?.resume()
        }
    }
}

// MARK: - Session.Operations.Admission

extension Session.Operations {
    enum Admission {
        case queued
        case immediate
    }
}

// MARK: - Session.Operations.Ticket

private extension Session.Operations {
    final class Ticket: Sendable {}
}

// MARK: - Session.Operations.Waiter

private extension Session.Operations {
    enum Waiter {
        case operation(Ticket, CheckedContinuation<Void, any Swift::Error>)
        case closing(CheckedContinuation<Void, Never>)

        var ticket: Ticket? {
            if case let .operation(ticket, _) = self {
                ticket
            } else {
                nil
            }
        }

        func resume() {
            switch self {
            case let .operation(_, continuation):
                continuation.resume()
            case let .closing(continuation):
                continuation.resume()
            }
        }
    }
}

// MARK: - Session.Operations.State

private extension Session.Operations {
    struct State {
        // nil means idle. An empty queue can still have an active reservation.
        private var waiters: [Waiter]?

        mutating func reserve() -> Bool {
            guard waiters == nil else {
                return false
            }
            waiters = []
            return true
        }

        mutating func enqueue(_ waiter: Waiter) -> Bool {
            if reserve() {
                return true
            }
            waiters?.append(waiter)
            return false
        }

        mutating func removeOperation(
            _ ticket: Ticket,
        ) -> CheckedContinuation<Void, any Swift::Error>? {
            guard
                let index = waiters?.firstIndex(where: { $0.ticket === ticket }),
                case let .operation(_, continuation)? = waiters?.remove(at: index)
            else {
                return nil
            }
            return continuation
        }

        mutating func advance() -> Waiter? {
            guard waiters?.isEmpty == false else {
                waiters = nil
                return nil
            }
            return waiters?.removeFirst()
        }
    }
}

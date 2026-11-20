//
//  Created by Anton Spivak
//

import Synchronization

extension Context {
    final class Invocation: Sendable {
        private struct State {
            var active = true

            // The callback already retains its context and this invocation.
            weak var callback: Session.Control.ExportCall?
        }

        private let state: Mutex = .init(State())

        var isActive: Bool {
            state.withLock { $0.active }
        }

        func checkActive() throws {
            guard isActive else {
                throw Failure.closed
            }
        }

        func bind(_ callback: Session.Control.ExportCall) {
            state.withLock { $0.callback = callback }
        }

        func callback() throws -> Session.Control.ExportCall {
            try state.withLock { state in
                guard state.active, let callback = state.callback else {
                    throw Failure.closed
                }
                return callback
            }
        }

        func finish() {
            state.withLock { $0.active = false }
        }
    }
}

//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

extension Reference {
    // Python pointers are stored as integers under the mutex. They are dereferenced
    // and released only while this interpreter's thread state is attached.
    final class Store: Sendable {
        private struct State {
            var isActive: Bool = true

            var nextToken: UInt64 = 0
            var pointersByToken: [UInt64: UInt] = [:]

            var pendingReleases: [UInt] = []
            var isScheduled: Bool = false

            mutating func takePendingReleases() -> [UInt] {
                isScheduled = false
                return exchange(&pendingReleases, with: [])
            }
        }

        private let state: Mutex<State> = .init(State())
        private let schedule: @Sendable () -> Void

        init(schedule: @escaping @Sendable () -> Void) {
            self.schedule = schedule
        }

        @unsafe
        func retain(_ pointer: UnsafeMutablePointer<PyObject>) throws -> Reference {
            // A rejected insertion must drop its retain after unlocking.
            let retained = unsafe Object.retaining(pointer, in: self)

            let token = state.withLock { state -> UInt64? in
                guard state.isActive else {
                    return nil
                }
                let token = state.nextToken
                state.nextToken += 1
                state.pointersByToken[token] = UInt(bitPattern: pointer)
                return token
            }
            guard let token else {
                throw Exception(
                    name: "ReferenceError",
                    message: "The Python interpreter is closed.",
                )
            }

            _ = unsafe retained.release()
            return Reference(storage: .init(references: self, token: token))
        }

        func release(_ token: UInt64) {
            let shouldScheduleRelease = state.withLock { state in
                guard let pointer = state.pointersByToken.removeValue(forKey: token) else {
                    return false
                }
                state.pendingReleases.append(pointer)
                guard !state.isScheduled else {
                    return false
                }
                state.isScheduled = true
                return true
            }
            if shouldScheduleRelease {
                schedule()
            }
        }

        @unsafe
        func pointer(_ token: UInt64) throws -> UnsafeMutablePointer<PyObject> {
            guard
                let bits = state.withLock({ $0.isActive ? $0.pointersByToken[token] : nil }),
                let pointer = unsafe UnsafeMutablePointer<PyObject>(bitPattern: bits)
            else {
                throw Exception(
                    name: "ReferenceError",
                    message: "The Python reference belongs to an expired session generation.",
                )
            }
            return unsafe pointer
        }

        func releasePendingReferences() {
            let pendingReleases = state.withLock { $0.takePendingReleases() }
            // A final DECREF can run Python code, so release outside the mutex.
            unsafe Object.decrementReferences(pendingReleases)
        }

        func close() {
            let pendingReleases = state.withLock { state in
                state.isActive = false
                let active = exchange(&state.pointersByToken, with: [:])
                return Array(active.values) + state.takePendingReleases()
            }
            unsafe Object.decrementReferences(pendingReleases)
        }
    }
}

//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

// MARK: - Reference.Store

extension Reference {
    // Python pointers are stored as integers under the mutex. They are dereferenced
    // and released only while this interpreter's thread state is attached.
    final class Store: Sendable {
        private let state: Mutex<State> = .init(State())
        private let schedule: @Sendable () -> Void

        init(schedule: @escaping @Sendable () -> Void) {
            self.schedule = schedule
        }

        @unsafe
        func retain(_ pointer: UnsafeMutablePointer<PyObject>) throws -> Reference {
            // A rejected insertion must drop its retain after unlocking.
            let retained = unsafe Object.retaining(pointer, in: self)

            let bits = UInt(bitPattern: pointer)
            guard let token = state.withLock({ $0.insert(bits) }) else {
                throw Exception(
                    name: "ReferenceError",
                    message: "The Python interpreter is closed.",
                )
            }

            _ = unsafe retained.release()
            return Reference(storage: .init(references: self, token: token))
        }

        func release(_ token: UInt64) {
            if state.withLock({ $0.enqueueRelease(of: token) }) {
                schedule()
            }
        }

        @unsafe
        func pointer(_ token: UInt64) throws -> UnsafeMutablePointer<PyObject> {
            guard
                let bits = state.withLock({ $0.pointer(for: token) }),
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

        func beginCheckpoint() {
            state.withLock { $0.beginCheckpoint() }
        }

        // Finish after the interpreter has restored or committed its memory.
        func finishCheckpoint(restoring: Bool) {
            let releases = state.withLock { $0.finishCheckpoint(restoring: restoring) }
            unsafe Object.decrementReferences(releases)
        }

        func close() {
            let pendingReleases = state.withLock { $0.close() }
            unsafe Object.decrementReferences(pendingReleases)
        }
    }
}

// MARK: - Reference.Store.State

private extension Reference.Store {
    struct Checkpoint {
        var pointersByToken: [UInt64: UInt] = [:]
        var releases: [UInt]
    }

    struct State {
        var isActive: Bool = true

        var nextToken: UInt64 = 0
        var pointersByToken: [UInt64: UInt] = [:]

        var pendingReleases: [UInt] = []
        var isScheduled: Bool = false

        var checkpoint: Checkpoint?

        mutating func insert(_ pointer: UInt) -> UInt64? {
            guard isActive else {
                return nil
            }
            let token = nextToken
            nextToken += 1

            if checkpoint != nil {
                checkpoint?.pointersByToken[token] = pointer
            } else {
                pointersByToken[token] = pointer
            }
            return token
        }

        func pointer(for token: UInt64) -> UInt? {
            guard isActive else {
                return nil
            }
            return checkpoint?.pointersByToken[token] ?? pointersByToken[token]
        }

        mutating func enqueueRelease(of token: UInt64) -> Bool {
            let pointer: UInt
            if let created = checkpoint?.pointersByToken.removeValue(forKey: token) {
                pointer = created
            } else {
                guard let existing = pointersByToken.removeValue(forKey: token) else {
                    return false
                }
                if checkpoint != nil {
                    checkpoint?.releases.append(existing)
                    return false
                }
                pointer = existing
            }

            pendingReleases.append(pointer)
            guard !isScheduled else {
                return false
            }
            isScheduled = true
            return true
        }

        mutating func takePendingReleases() -> [UInt] {
            isScheduled = false
            return exchange(&pendingReleases, with: [])
        }

        mutating func beginCheckpoint() {
            precondition(isActive && checkpoint == nil)
            // Pending releases still contribute to the saved refcounts.
            let releases = takePendingReleases()
            checkpoint = Checkpoint(releases: releases)
        }

        mutating func finishCheckpoint(restoring: Bool) -> [UInt] {
            guard var saved = exchange(&checkpoint, with: nil) else {
                preconditionFailure("A Python reference checkpoint is not active.")
            }
            let pending = takePendingReleases()
            // Rollback restores refcounts. Only commit applies speculative releases.
            if !restoring {
                pointersByToken.merge(saved.pointersByToken) { _, _ in
                    preconditionFailure("A Python reference token cannot be reused.")
                }
                saved.releases.append(contentsOf: pending)
            }
            return saved.releases
        }

        mutating func close() -> [UInt] {
            precondition(checkpoint == nil)
            isActive = false

            let active = exchange(&pointersByToken, with: [:])
            return Array(active.values) + takePendingReleases()
        }
    }
}

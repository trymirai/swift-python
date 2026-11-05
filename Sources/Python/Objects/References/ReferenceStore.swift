//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

// Python pointers are stored as integers under the mutex. They are dereferenced
// and released only while this interpreter's thread state is attached.
final class ReferenceStore: Sendable {
    private struct State {
        var isActive: Bool = true

        var nextToken: UInt64 = 0
        var pointersByToken: [UInt64: UInt] = [:]

        var pendingReleases: [UInt] = []

        var isScheduled: Bool = false
    }

    private let state: Mutex<State> = .init(State())
    private let schedule: @Sendable () -> Void

    init(schedule: @escaping @Sendable () -> Void) {
        self.schedule = schedule
    }

    @unsafe
    func retain(_ pointer: UnsafeMutablePointer<PyObject>) throws -> Reference {
        unsafe Py_IncRef(pointer)
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
            unsafe Py_DecRef(pointer)
            throw Exception(
                name: "ReferenceError",
                message: "The Python interpreter is closed.",
            )
        }
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
        let pendingReleases = state.withLock { state in
            let result = state.pendingReleases
            state.pendingReleases = []
            state.isScheduled = false
            return result
        }
        for bits in pendingReleases {
            if let pointer = unsafe UnsafeMutablePointer<PyObject>(bitPattern: bits) {
                unsafe Py_DecRef(pointer)
            }
        }
    }

    func close() {
        let pendingReleases = state.withLock { state in
            state.isActive = false
            let result = Array(state.pointersByToken.values) + state.pendingReleases
            state.pointersByToken = [:]
            state.pendingReleases = []
            state.isScheduled = false
            return result
        }
        for bits in pendingReleases {
            if let pointer = unsafe UnsafeMutablePointer<PyObject>(bitPattern: bits) {
                unsafe Py_DecRef(pointer)
            }
        }
    }
}

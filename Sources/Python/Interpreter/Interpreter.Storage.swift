//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

// MARK: - Interpreter.Storage

extension Interpreter {
    @safe
    final class Storage {
        // Entries borrow PThread storage until interpreter destruction completes.
        private static let registry: Mutex<[UInt: UInt]> = .init([:])

        let key: UInt
        let heap: OpaquePointer?

        let references: Reference.Store

        let fileAccess: Interpreter.FileAccess?
        weak var session: Session?

        private var isClosed: Bool = false
        var checkpoint: CheckpointState = .inactive

        var namespace: Reference?

        var classRegistry: Interpreter.ClassRegistry?
        var defaultArgumentMarker: UInt = 0
        private var nextCallID: Int = 0

        var arrayType: Reference?
        private var borrowedBuffers: [BufferBorrow] = []
        private var nextBorrowID: UInt64 = 0

        // Buffer borrows defer releases that could reenter Python.
        private var pendingBufferReleases: [UInt] = []
        private var pendingObjectReleases: [UInt] = []

        var execution: Session.Control? {
            PThread.Scope.current?.execution
        }

        init(
            key: UInt,
            heap: OpaquePointer?,
            view: Interpreter.View,
            fileAccess: Interpreter.FileAccess?,
            schedule: @escaping @Sendable () -> Void,
        ) {
            self.key = key
            unsafe self.heap = heap
            self.fileAccess = fileAccess
            self.references = Reference.Store(view: view, schedule: schedule)

            let pointer = unsafe UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
            Self.registry.withLock { $0[key] = pointer }
        }

        static func current() -> Interpreter.Storage? {
            let key = CPython_InterpreterKey(nil)
            return lookup(key)
        }

        static func lookup(_ key: UInt) -> Interpreter.Storage? {
            guard
                key != 0, let bits = registry.withLock({ $0[key] }),
                let pointer = unsafe UnsafeRawPointer(bitPattern: bits)
            else {
                return nil
            }
            return unsafe Unmanaged<Interpreter.Storage>.fromOpaque(pointer).takeUnretainedValue()
        }

        static func requireCurrent() throws -> Interpreter.Storage {
            guard let state = current(), !state.isClosed else {
                throw Session.Error.closed
            }

            try state.checkTaskAttachment()
            try state.checkReentry()
            return state
        }

        private func checkTaskAttachment() throws {
            // Task.immediate can start on the attached thread before suspending.
            guard
                let scope = PThread.Scope.current, scope.storage === self,
                scope.matchesTask
            else {
                throw Exception(
                    name: "RuntimeError",
                    message: "Python is attached to another Swift task.",
                )
            }
        }

        private func checkReentry() throws {
            guard checkpoint != .settling else {
                throw Exception(
                    name: "RuntimeError",
                    message: "The interpreter is restoring its execution state.",
                )
            }

            guard borrowedBuffers.isEmpty else {
                throw Exception(
                    name: "RuntimeError",
                    message: "Python reentry is unavailable while a buffer is borrowed.",
                )
            }
        }

        func settleCheckpoint(_ body: () -> Void) {
            precondition(checkpoint == .active)
            checkpoint = .settling
            body()
            checkpoint = .inactive
        }

        func allocateCallID() -> Session.Control.CallID {
            let id = nextCallID
            nextCallID += 1
            return .init(rawValue: id)
        }

        @unsafe
        static func release(_ pointer: UnsafeMutablePointer<PyObject>) {
            guard let state = current(), !state.borrowedBuffers.isEmpty else {
                unsafe Py_DecRef(pointer)
                return
            }

            state.pendingObjectReleases.append(UInt(bitPattern: pointer))
        }

        func withConstructionScope<Result: ~Copyable>(
            _ body: () throws -> Result,
        ) rethrows -> Result {
            // A nested Swift callback releases only the wrappers it created.
            guard let scope = PThread.Scope.current else {
                preconditionFailure("Missing Python attachment scope.")
            }
            let boundary = scope.constructedWrappers.count
            defer {
                scope.constructedWrappers.removeSubrange(boundary...)
                releasePendingReferences()
            }
            return try body()
        }

        func retainConstructedWrapper(_ wrapper: borrowing Object) throws {
            let reference = unsafe try references.retain(wrapper.pointer)
            guard let scope = PThread.Scope.current else {
                throw Session.Error.closed
            }
            scope.constructedWrappers.append(reference)
        }

        func releasePendingReferences() {
            guard borrowedBuffers.isEmpty else {
                return
            }

            references.releasePendingReferences()
            releasePendingBuffers()
            releasePendingObjects()
        }

        private func releasePendingBuffers() {
            // Releasing a buffer or object can reenter Python. Drain a detached batch.
            while !pendingBufferReleases.isEmpty {
                let buffers = exchange(&pendingBufferReleases, with: [])
                for bits in buffers {
                    if let pointer = unsafe UnsafeMutablePointer<Py_buffer>(bitPattern: bits) {
                        unsafe Self.destroyBuffer(pointer)
                    }
                }
            }
        }

        private func releasePendingObjects() {
            while !pendingObjectReleases.isEmpty {
                let values = exchange(&pendingObjectReleases, with: [])
                unsafe Object.decrementReferences(values)
            }
        }

        func close() {
            isClosed = true

            classRegistry = nil
            namespace = nil
            arrayType = nil

            references.close()
            releasePendingReferences()
        }

        func unregister() {
            _ = Self.registry.withLock { $0.removeValue(forKey: key) }
        }
    }
}

extension Interpreter.Storage {
    @unsafe
    func beginBufferBorrow(_ buffer: UnsafePointer<Py_buffer>, isMutable: Bool) throws -> UInt64 {
        guard Self.current() === self, !isClosed else {
            throw Reference.wrongInterpreter()
        }

        let address = unsafe UInt(bitPattern: buffer.pointee.buf)
        let byteCount = unsafe UInt(buffer.pointee.len)
        let overlapsWritableBorrow = borrowedBuffers.contains { borrow in
            (isMutable || borrow.isMutable) && borrow.overlaps(
                address: address,
                byteCount: byteCount,
            )
        }
        if overlapsWritableBorrow {
            throw Exception(
                name: "BufferError",
                message: "Overlapping writable Python buffer arguments are not allowed.",
            )
        }

        let id = nextBorrowID
        nextBorrowID &+= 1
        borrowedBuffers.append(BufferBorrow(
            id: id,
            address: address,
            byteCount: byteCount,
            isMutable: isMutable,
        ))
        return id
    }

    func endBufferBorrow(_ id: UInt64) {
        borrowedBuffers.removeAll { $0.id == id }
        releasePendingReferences()
    }

    @unsafe
    func releaseBuffer(_ pointer: UnsafeMutablePointer<Py_buffer>) {
        if borrowedBuffers.isEmpty {
            unsafe Self.destroyBuffer(pointer)
        } else {
            pendingBufferReleases.append(UInt(bitPattern: pointer))
        }
    }

    @unsafe
    private static func destroyBuffer(_ pointer: UnsafeMutablePointer<Py_buffer>) {
        unsafe PyBuffer_Release(pointer)
        unsafe pointer.deinitialize(count: 1)
        unsafe pointer.deallocate()
    }
}

// MARK: - Interpreter.Storage.BufferBorrow

private extension Interpreter.Storage {
    struct BufferBorrow {
        let id: UInt64

        let address: UInt
        let byteCount: UInt
        let isMutable: Bool

        func overlaps(address other: UInt, byteCount otherByteCount: UInt) -> Bool {
            guard byteCount != 0, otherByteCount != 0 else {
                return false
            }

            // Subtract addresses to avoid overflowing the end of a range.
            if address >= other {
                return address - other < otherByteCount
            }
            return other - address < byteCount
        }
    }
}

// MARK: - Interpreter.Storage.CheckpointState

extension Interpreter.Storage {
    enum CheckpointState {
        case inactive
        case active
        case settling
    }
}

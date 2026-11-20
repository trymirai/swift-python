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
        let references: Reference.Store
        let fileAccess: Interpreter.FileAccess?
        private var isClosed: Bool = false

        var namespace: Reference?
        var arrayType: Reference?

        var classRegistry: Interpreter.ClassRegistry?
        var defaultArgumentMarker: UInt = 0
        private var nextCallID: Int = 0

        private weak var currentOperation: Session.Control?
        // Borrowed from the active operation context under this interpreter's GIL.
        private var operationMarker: UnsafeMutablePointer<PyObject>?

        private var borrowedBuffers: [BufferBorrow] = []
        private var nextBorrowID: UInt64 = 0

        // Buffer borrows defer releases that could reenter Python.
        private var pendingBufferReleases: [UInt] = []
        private var pendingObjectReleases: [UInt] = []

        init(
            key: UInt,
            view: Interpreter.View,
            session: Session?,
            fileAccess: Interpreter.FileAccess?,
            schedule: @escaping @Sendable () -> Void,
        ) {
            self.key = key
            self.references = Reference.Store(view: view, session: session, schedule: schedule)
            self.fileAccess = fileAccess

            let pointer = unsafe UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
            Self.registry.withLock { $0[key] = pointer }
        }

        static func current() -> Interpreter.Storage? {
            let key = CPython_InterpreterKey(nil)
            return lookup(key)
        }

        static func lookup(_ key: UInt) -> Interpreter.Storage? {
            guard
                key != 0,
                let bits = registry.withLock({ $0[key] }),
                let pointer = unsafe UnsafeRawPointer(bitPattern: bits)
            else {
                return nil
            }
            return unsafe Unmanaged<Interpreter.Storage>.fromOpaque(pointer).takeUnretainedValue()
        }

        static func requireCurrent() throws -> Interpreter.Storage {
            guard let scope = PThread.Scope.current else {
                throw Failure.closed
            }
            let storage = scope.storage
            guard CPython_InterpreterKey(nil) == storage.key, !storage.isClosed else {
                throw Failure.closed
            }

            // Task.immediate can start on the attached thread before suspending.
            guard scope.matchesTask else {
                throw Failure(.runtimeError, message: "Python is attached to another Swift task.")
            }
            try storage.checkReentry()
            return storage
        }

        private func checkReentry() throws {
            guard borrowedBuffers.isEmpty else {
                throw Failure(
                    .runtimeError,
                    message: "Python reentry is unavailable while a buffer is borrowed.",
                )
            }
        }

        var execution: Session.Control? {
            PThread.Scope.current?.execution
        }

        func withOperationContext<Result: ~Copyable>(
            _ execution: Session.Control,
            forCallback: Bool,
            _ body: () throws -> Result,
        ) throws -> Result {
            if forCallback, currentOperation !== execution {
                throw Failure.closed
            }

            var context = unsafe CPython_OperationContext()
            return try withUnsafeMutablePointer(to: &context) { pointer in
                try Object.check(
                    unsafe CPython_EnterOperationContext(
                        pointer,
                        forCallback ? operationMarker : nil,
                    ),
                    "Unable to enter the Python operation context.",
                )
                defer { unsafe CPython_LeaveOperationContext(pointer) }

                guard !forCallback else {
                    return try body()
                }

                currentOperation = execution
                unsafe operationMarker = pointer.pointee.marker
                defer {
                    unsafe operationMarker = nil
                    currentOperation = nil
                }

                return try body()
            }
        }

        func allocateCallID() -> Session.Control.CallID {
            let id = nextCallID
            nextCallID += 1
            return .init(rawValue: id)
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
                throw Failure.closed
            }
            scope.constructedWrappers.append(reference)
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
    static func release(_ pointer: UnsafeMutablePointer<PyObject>) {
        guard let state = current(), !state.borrowedBuffers.isEmpty else {
            unsafe Py_DecRef(pointer)
            return
        }

        state.pendingObjectReleases.append(UInt(bitPattern: pointer))
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

    @unsafe
    func beginBufferBorrow(_ buffer: UnsafePointer<Py_buffer>, isMutable: Bool) throws -> UInt64 {
        guard Self.current() === self, !isClosed else {
            throw Reference.wrongInterpreter()
        }

        let borrow = BufferBorrow(
            id: nextBorrowID,
            address: unsafe UInt(bitPattern: buffer.pointee.buf),
            byteCount: unsafe UInt(buffer.pointee.len),
            isMutable: isMutable,
        )
        guard !borrowedBuffers.contains(where: borrow.conflicts(with:)) else {
            throw Failure(
                .bufferError,
                message: "Overlapping writable Python buffer arguments are not allowed.",
            )
        }

        nextBorrowID &+= 1
        borrowedBuffers.append(borrow)
        return borrow.id
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

        func conflicts(with other: BufferBorrow) -> Bool {
            guard isMutable || other.isMutable, byteCount != 0, other.byteCount != 0 else {
                return false
            }

            // Subtract addresses to avoid overflowing the end of a range.
            if address >= other.address {
                return address - other.address < other.byteCount
            }
            return other.address - address < byteCount
        }
    }
}

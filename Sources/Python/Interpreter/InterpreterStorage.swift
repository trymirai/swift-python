//
//  Created by Anton Spivak
//

internal import libcpython
import Synchronization

// MARK: - InterpreterStorage

// The registry borrows each ThreadState's storage, and only attached callbacks
// can look it up. Entries are removed after interpreter destruction completes.
final class InterpreterStorage {
    private struct BufferBorrow {
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

    private static let registry: Mutex<[UInt: UInt]> = .init([:])

    let key: UInt
    let references: ReferenceStore
    private var isClosed: Bool = false

    var sessionOrigin: ObjectIdentifier?
    var execution: ExecutionControl?

    var defaultArgumentMarker: UInt = 0
    var classRegistry: ClassRegistry?
    var arrayType: Reference?

    private var borrowedBuffers: [BufferBorrow] = []
    private var nextBorrowID: UInt64 = 0

    private var pendingBufferReleases: [UInt] = []
    private var pendingObjectReleases: [UInt] = []

    init(key: UInt, schedule: @escaping @Sendable () -> Void) {
        self.key = key
        self.references = ReferenceStore(schedule: schedule)
        let pointer = unsafe UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        Self.registry.withLock { $0[key] = pointer }
    }

    static func current() -> InterpreterStorage? {
        let key = CPython_InterpreterKey(nil)
        guard
            key != 0, let bits = registry.withLock({ $0[key] }),
            let pointer = unsafe UnsafeRawPointer(bitPattern: bits)
        else {
            return nil
        }
        return unsafe Unmanaged<InterpreterStorage>.fromOpaque(pointer).takeUnretainedValue()
    }

    static func requireCurrent() throws -> InterpreterStorage {
        guard let state = current(), !state.isClosed else {
            throw SessionError.closed
        }
        guard state.borrowedBuffers.isEmpty else {
            throw Exception(
                name: "RuntimeError",
                message: "Python reentry is unavailable while a buffer is borrowed.",
            )
        }
        return state
    }

    @unsafe
    static func release(_ pointer: UnsafeMutablePointer<PyObject>) {
        if let state = current(), !state.borrowedBuffers.isEmpty {
            state.pendingObjectReleases.append(UInt(bitPattern: pointer))
        } else {
            unsafe Py_DecRef(pointer)
        }
    }

    func releasePendingReferences() {
        guard borrowedBuffers.isEmpty else {
            return
        }
        references.releasePendingReferences()
        while !pendingBufferReleases.isEmpty {
            let buffers = pendingBufferReleases
            pendingBufferReleases = []
            for bits in buffers {
                if let pointer = unsafe UnsafeMutablePointer<Py_buffer>(bitPattern: bits) {
                    unsafe Self.destroyBuffer(pointer)
                }
            }
        }
        while !pendingObjectReleases.isEmpty {
            let values = pendingObjectReleases
            pendingObjectReleases = []
            for bits in values {
                if let pointer = unsafe UnsafeMutablePointer<PyObject>(bitPattern: bits) {
                    unsafe Py_DecRef(pointer)
                }
            }
        }
    }

    func close() {
        isClosed = true
        classRegistry = nil
        arrayType = nil
        references.close()
        releasePendingReferences()
    }

    func unregister() {
        _ = Self.registry.withLock { $0.removeValue(forKey: key) }
    }
}

extension InterpreterStorage {
    @unsafe
    func beginBufferBorrow(_ buffer: UnsafePointer<Py_buffer>, isMutable: Bool) throws -> UInt64 {
        guard Self.current() === self, !isClosed else {
            throw Reference.wrongInterpreter()
        }
        let address = unsafe UInt(bitPattern: buffer.pointee.buf)
        let byteCount = unsafe UInt(buffer.pointee.len)
        for borrow in borrowedBuffers where isMutable || borrow.isMutable {
            if borrow.overlaps(address: address, byteCount: byteCount) {
                throw Exception(
                    name: "BufferError",
                    message: "Overlapping writable Python buffer arguments are not allowed.",
                )
            }
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

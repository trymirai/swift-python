//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - BufferLease

/// Pins a contiguous, native-format buffer for reading within the interpreter scope.
@safe
public struct BufferLease<Element: BitwiseCopyable>: ~Copyable, ~Escapable {
    private let view: UnsafeMutablePointer<Py_buffer>
    private let storage: Interpreter.Storage

    @_lifetime(borrow owner)
    @unsafe
    init<Owner: ~Copyable & ~Escapable>(
        _ object: UnsafeMutablePointer<PyObject>,
        in owner: borrowing Owner,
    ) throws {
        self = unsafe try BufferLease(object, isWritable: false, in: owner)
    }

    @_lifetime(borrow owner)
    @unsafe
    private init<Owner: ~Copyable & ~Escapable>(
        _ object: UnsafeMutablePointer<PyObject>,
        isWritable: Bool,
        in owner: borrowing Owner,
    ) throws {
        let storage = try Interpreter.Storage.requireCurrent()
        unsafe try Self.requireSupported(object, isWritable: isWritable, in: storage)

        let view = unsafe try Self.acquire(object, isWritable: isWritable)
        do {
            unsafe try Self.validate(view)
        } catch {
            unsafe storage.releaseBuffer(view)
            throw error
        }

        unsafe self.view = view
        self.storage = storage
    }

    deinit {
        unsafe storage.releaseBuffer(view)
    }

    public var count: Int {
        unsafe view.pointee.len / MemoryLayout<Element>.stride
    }

    public borrowing func withSpan<Result: ~Copyable>(
        _ body: (Span<Element>) throws -> Result,
    ) throws -> Result {
        try withBorrow(isMutable: false) {
            let span = unsafe Span<Element>(_unsafeStart: baseAddress, count: count)
            let scoped = unsafe _overrideLifetime(span, borrowing: self)
            return try body(scoped)
        }
    }

    private borrowing func withMutableSpan<Result: ~Copyable>(
        _ body: (inout MutableSpan<Element>) throws -> Result,
    ) throws -> Result {
        try withBorrow(isMutable: true) {
            let span = unsafe MutableSpan<Element>(_unsafeStart: baseAddress, count: count)
            var scoped = unsafe _overrideLifetime(consume span, borrowing: self)
            return try body(&scoped)
        }
    }

    private borrowing func withBorrow<Result: ~Copyable>(
        isMutable: Bool,
        _ body: () throws -> Result,
    ) throws -> Result {
        let borrowID = unsafe try storage.beginBufferBorrow(view, isMutable: isMutable)
        defer { storage.endBufferBorrow(borrowID) }
        return try body()
    }

    @unsafe
    private var baseAddress: UnsafeMutablePointer<Element> {
        // Even an empty span requires a non-null, aligned address.
        let address = unsafe view.pointee.buf
            ?? UnsafeMutableRawPointer(bitPattern: MemoryLayout<Element>.alignment)!
        return unsafe address.assumingMemoryBound(to: Element.self)
    }

    @unsafe
    private static func requireSupported(
        _ object: UnsafeMutablePointer<PyObject>,
        isWritable: Bool,
        in storage: Interpreter.Storage,
    ) throws {
        guard let arrayType = storage.arrayType else {
            throw Session.Error.closed
        }

        let array = unsafe try arrayType.storage.pointer()
        guard unsafe CPython_BufferIsSupported(object, isWritable ? 1 : 0, array) != 0 else {
            throw invalid("Expected bytes, bytearray, array.array or their memoryview.")
        }
    }

    @unsafe
    private static func acquire(
        _ object: UnsafeMutablePointer<PyObject>,
        isWritable: Bool,
    ) throws -> UnsafeMutablePointer<Py_buffer> {
        let view = UnsafeMutablePointer<Py_buffer>.allocate(capacity: 1)
        unsafe view.initialize(to: Py_buffer())

        let flags = PyBUF_FORMAT | PyBUF_STRIDES | (isWritable ? PyBUF_WRITABLE : 0)
        guard unsafe PyObject_GetBuffer(object, view, flags) == 0 else {
            unsafe view.deinitialize(count: 1)
            unsafe view.deallocate()
            throw Object.failure("Unable to acquire a Python buffer.")
        }
        return unsafe view
    }

    @unsafe
    private static func validate(_ view: UnsafeMutablePointer<Py_buffer>) throws {
        let stride = MemoryLayout<Element>.stride
        let size = unsafe view.pointee.len
        let cOrder = CChar(UInt8(ascii: "C"))

        guard
            unsafe view.pointee.ndim == 1, unsafe PyBuffer_IsContiguous(view, cOrder) != 0,
            size >= 0, unsafe (size == 0 || view.pointee.buf != nil),
            unsafe view.pointee.itemsize == stride, size % stride == 0,
            let format = unsafe view.pointee.format
        else {
            throw invalid(
                "Expected a one-dimensional contiguous buffer with a matching element size.",
            )
        }

        unsafe try validateFormat(format)

        if
            let start = unsafe view.pointee.buf,
            Int(bitPattern: start) % MemoryLayout<Element>.alignment != 0
        {
            throw invalid("Python buffer is not aligned for \(Element.self).")
        }
    }

    @unsafe
    private static func validateFormat(_ format: UnsafePointer<CChar>) throws {
        var code = unsafe String(cString: format)
        if code.first == "@" || code.first == "=" {
            code.removeFirst()
        }
        guard accepts(format: code) else {
            throw invalid(
                "Python buffer format does not match \(Element.self) in native byte order.",
            )
        }
    }

    private static func invalid(_ message: String) -> Exception {
        Exception(
            name: "BufferError",
            message: message,
        )
    }

    private static func accepts(format: String) -> Bool {
        switch ObjectIdentifier(Element.self) {
        case ObjectIdentifier(UInt8.self):
            format == "B"
        case ObjectIdentifier(Int8.self):
            format == "b"
        case ObjectIdentifier(Int16.self):
            format == "h"
        case ObjectIdentifier(UInt16.self):
            format == "H"
        case ObjectIdentifier(Int32.self):
            format == "i" ||
                (MemoryLayout<CLong>.size == 4 && format == "l")
        case ObjectIdentifier(UInt32.self):
            format == "I" || (MemoryLayout<CUnsignedLong>.size == 4 && format == "L")
        case ObjectIdentifier(Int64.self), ObjectIdentifier(Int.self):
            format == "q" || format == "n" || (MemoryLayout<CLong>.size == 8 && format == "l")
        case ObjectIdentifier(UInt64.self), ObjectIdentifier(UInt.self):
            format == "Q" || format == "N" ||
                (MemoryLayout<CUnsignedLong>.size == 8 && format == "L")
        case ObjectIdentifier(Float.self):
            format == "f"
        case ObjectIdentifier(Double.self):
            format == "d"
        default:
            false
        }
    }
}

// MARK: BufferLease.Mutable

public extension BufferLease {
    /// Pins a writable buffer. A mutable view excludes overlapping aliases and Python reentry.
    struct Mutable: ~Copyable, ~Escapable {
        private let lease: BufferLease<Element>

        @_lifetime(borrow owner)
        @unsafe
        init<Owner: ~Copyable & ~Escapable>(
            _ object: UnsafeMutablePointer<PyObject>,
            in owner: borrowing Owner,
        ) throws {
            lease = unsafe try BufferLease(object, isWritable: true, in: owner)
        }

        public var count: Int {
            lease.count
        }

        public borrowing func withSpan<Result: ~Copyable>(
            _ body: (Span<Element>) throws -> Result,
        ) throws -> Result {
            try lease.withSpan(body)
        }

        public borrowing func withMutableSpan<Result: ~Copyable>(
            _ body: (inout MutableSpan<Element>) throws -> Result,
        ) throws -> Result {
            try lease.withMutableSpan(body)
        }
    }
}

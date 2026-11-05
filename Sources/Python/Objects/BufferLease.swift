//
//  Created by Anton Spivak
//

internal import libcpython

/// Pins a contiguous, native-format buffer until the interpreter scope ends.
/// Views cannot escape their closure. Mutable views exclude overlapping aliases and Python reentry.
@safe
public struct BufferLease<Element: BitwiseCopyable>: ~Copyable, ~Escapable {
    private let view: UnsafeMutablePointer<Py_buffer>
    private let storage: InterpreterStorage
    private let isWritable: Bool

    @_lifetime(borrow owner)
    @unsafe
    init<Owner: ~Copyable & ~Escapable>(
        _ object: UnsafeMutablePointer<PyObject>,
        isWritable: Bool,
        in owner: borrowing Owner,
    ) throws {
        let storage = try InterpreterStorage.requireCurrent()
        guard let arrayType = storage.arrayType else {
            throw SessionError.closed
        }

        let array = unsafe try arrayType.storage.references.pointer(arrayType.storage.token)
        guard unsafe CPython_BufferIsSupported(object, isWritable ? 1 : 0, array) != 0 else {
            throw Self.invalid("Expected bytes, bytearray, array.array or their memoryview.")
        }

        let view = UnsafeMutablePointer<Py_buffer>.allocate(capacity: 1)
        unsafe view.initialize(to: Py_buffer())

        let result = unsafe PyObject_GetBuffer(
            object,
            view,
            PyBUF_FORMAT | PyBUF_STRIDES | (isWritable ? PyBUF_WRITABLE : 0),
        )

        guard result == 0
        else {
            unsafe view.deinitialize(count: 1)
            unsafe view.deallocate()
            throw Object.failure("Unable to acquire a Python buffer.")
        }

        do {
            unsafe try Self.validate(view)
        } catch {
            unsafe storage.releaseBuffer(view)
            throw error
        }

        unsafe self.view = view
        self.storage = storage
        self.isWritable = isWritable
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
        let borrowID = unsafe try storage.beginBufferBorrow(view, isMutable: false)
        defer { storage.endBufferBorrow(borrowID) }
        let span = unsafe Span<Element>(
            _unsafeStart: baseAddress,
            count: count,
        )
        let scoped = unsafe _overrideLifetime(span, borrowing: self)
        return try body(scoped)
    }

    public borrowing func withMutableSpan<Result: ~Copyable>(
        _ body: (inout MutableSpan<Element>) throws -> Result,
    ) throws -> Result {
        guard isWritable
        else {
            throw Self.invalid("Acquire a writable buffer before requesting a mutable span.")
        }
        let borrowID = unsafe try storage.beginBufferBorrow(view, isMutable: true)
        defer { storage.endBufferBorrow(borrowID) }
        let span = unsafe MutableSpan<Element>(
            _unsafeStart: baseAddress,
            count: count,
        )
        var scoped = unsafe _overrideLifetime(consume span, borrowing: self)
        return try body(&scoped)
    }

    @unsafe
    private var baseAddress: UnsafeMutablePointer<Element> {
        // Even an empty span requires a non-null, aligned address.
        let address = unsafe view.pointee.buf
            ?? UnsafeMutableRawPointer(bitPattern: MemoryLayout<Element>.alignment)!
        return unsafe address.assumingMemoryBound(to: Element.self)
    }

    @unsafe
    private static func validate(_ view: UnsafeMutablePointer<Py_buffer>) throws {
        let stride = MemoryLayout<Element>.stride
        let size = unsafe view.pointee.len
        guard
            unsafe view.pointee.ndim == 1, unsafe PyBuffer_IsContiguous(view, 67) != 0,
            size >= 0, unsafe (size == 0 || view.pointee.buf != nil),
            unsafe view.pointee.itemsize == stride, size % stride == 0,
            let format = unsafe view.pointee.format
        else {
            throw invalid(
                "Expected a one-dimensional contiguous buffer with a matching element size.",
            )
        }

        var code = unsafe String(cString: format)
        if code.first == "@" || code.first == "=" {
            code.removeFirst()
        }
        guard accepts(format: code) else {
            throw invalid(
                "Python buffer format does not match \(Element.self) in native byte order.",
            )
        }

        if
            let start = unsafe view.pointee.buf,
            Int(bitPattern: start) % MemoryLayout<Element>.alignment != 0
        {
            throw invalid("Python buffer is not aligned for \(Element.self).")
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

//
//  Created by Anton Spivak
//

internal import libcpython

extension Object {
    static func check(_ status: CInt, _ message: String) throws {
        guard status == 0 else {
            throw failure(message)
        }
    }

    static func checkError(_ message: String) throws {
        guard unsafe PyErr_Occurred() == nil else {
            throw failure(message)
        }
    }

    static func require<T>(_ result: T?, _ message: String) throws -> T {
        guard let result else {
            throw failure(message)
        }
        return result
    }

    static func raise(_ error: any Swift.Error) {
        let name: ExceptionName
        let message: String
        if let failure = error as? Failure, case let .exception(exception) = failure.kind {
            // The C bridge looks up the name through a null-terminated string.
            name = exception.rawValue.utf8.contains(0) ? .runtimeError : exception
            message = failure.message
        } else {
            name = .runtimeError
            message = String(describing: error)
        }

        message.withCString { bytes in
            unsafe CPython_RaiseSwiftError(name.rawValue, bytes, message.utf8.count)
        }
    }

    static func failure(_ fallback: String) -> Failure {
        guard let exception = unsafe PyErr_GetRaisedException() else {
            return Failure(fallback)
        }
        defer { unsafe Py_DecRef(exception) }

        let name = unsafe takeExceptionText(CPython_ExceptionName(exception))
        let message = unsafe takeExceptionText(PyObject_Str(exception)) ?? fallback
        return Failure(name.map(ExceptionName.init(rawValue:)) ?? .runtimeError, message: message)
    }

    @unsafe
    private static func takeExceptionText(_ text: UnsafeMutablePointer<PyObject>?) -> String? {
        // Formatting the exception can raise a second one. Clear it before returning to Python.
        defer { PyErr_Clear() }
        guard let text = unsafe text else {
            return nil
        }
        defer { unsafe Py_DecRef(text) }

        guard let buffer = unsafe utf8Buffer(text) else {
            return nil
        }
        return String(copying: unsafe UTF8Span(unchecked: buffer.span))
    }
}

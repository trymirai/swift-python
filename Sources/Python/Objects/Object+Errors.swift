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

    static func raise(_ error: any Swift::Error) {
        if let exception = error as? Exception {
            unsafe CPython_RaiseSwiftError(exception.name, exception.message)
        } else {
            unsafe CPython_RaiseSwiftError("RuntimeError", String(describing: error))
        }
    }

    static func failure(_ message: String) -> any Swift::Error {
        func fallback() -> Runtime.Failure {
            // Formatting a Python exception can itself raise.
            PyErr_Clear()
            return Runtime.Failure(message)
        }

        guard let exception = unsafe PyErr_GetRaisedException() else {
            return Runtime.Failure(message)
        }
        defer {
            unsafe Py_DecRef(exception)
        }

        let name = unsafe String(cString: CPython_ExceptionName(exception))
        guard let text = unsafe PyObject_Str(exception) else {
            return fallback()
        }
        defer {
            unsafe Py_DecRef(text)
        }

        guard let buffer = unsafe utf8Buffer(text) else {
            return fallback()
        }

        let description = String(copying: unsafe UTF8Span(unchecked: buffer.span))
        return Exception(name: name, message: description)
    }
}

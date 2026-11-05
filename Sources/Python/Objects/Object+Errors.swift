//
//  Created by Anton Spivak
//

internal import libcpython

extension Object {
    static func failure(_ message: String) -> any Swift.Error {
        guard let exception = unsafe PyErr_GetRaisedException() else {
            return RuntimeFailure(message)
        }
        defer {
            unsafe Py_DecRef(exception)
        }
        let name = unsafe String(cString: CPython_ExceptionName(exception))
        guard let text = unsafe PyObject_Str(exception) else {
            PyErr_Clear()
            return RuntimeFailure(message)
        }
        defer {
            unsafe Py_DecRef(text)
        }

        var count = 0
        guard let bytes = unsafe PyUnicode_AsUTF8AndSize(text, &count) else {
            PyErr_Clear()
            return RuntimeFailure(message)
        }

        let span = unsafe Span<UInt8>(
            _unsafeStart: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
            count: count,
        )

        let description = String(copying: unsafe UTF8Span(unchecked: span))
        return Exception(name: name, message: description)
    }
}

//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Object.Callback

extension Object {
    private final class Callback {
        init(_ body: any Callable) {
            self.body = body
        }

        let body: any Callable
    }
}

// MARK: Object + Callbacks

extension Object {
    @_lifetime(borrow attachment)
    static func makeFunction(
        _ body: any Callable,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let context = unsafe Unmanaged.passRetained(Callback(body)).toOpaque()
        return unsafe try take(CPython_NewFunction(
            context,
            { context, arguments in unsafe Object.invoke(context, arguments) },
            { context in unsafe Object.releaseCallback(context) },
        ), in: attachment)
    }

    private static func invoke(
        _ context: UnsafeMutableRawPointer?,
        _ arguments: UnsafeMutablePointer<PyObject>?,
    ) -> UnsafeMutablePointer<PyObject>? {
        guard let context = unsafe context, let argumentsPointer = unsafe arguments else {
            unsafe CPython_RaiseSwiftError("RuntimeError", "Missing Swift callback arguments.")
            return nil
        }

        let callback = unsafe Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue()
        do {
            return unsafe try PThread.withCallbackAttachment { attachment in
                let arguments = unsafe Object.retaining(argumentsPointer, in: attachment)
                let result = try callback.body.call(arguments, in: attachment)
                return unsafe result.release()
            }
        } catch {
            Object.raise(error)
        }
        return nil
    }

    private static func releaseCallback(_ context: UnsafeMutableRawPointer?) {
        if let context = unsafe context {
            unsafe Unmanaged<Callback>.fromOpaque(context).release()
        }
    }
}

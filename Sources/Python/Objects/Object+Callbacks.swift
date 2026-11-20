//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Object.Callable

extension Object {
    // A method requirement preserves the result's lifetime dependency through
    // existential dispatch. Stored function values cannot express it in Swift 6.4.
    protocol Callable {
        @_lifetime(borrow attachment)
        func call(
            _ arguments: borrowing Object,
            in attachment: borrowing PThread.Attachment,
        ) throws -> Object
    }
}

// MARK: - Object.Callback

extension Object {
    private final class Callback {
        let body: any Callable

        init(_ body: any Callable) {
            self.body = body
        }
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
        let function = unsafe CPython_NewFunction(
            context,
            { context, arguments in unsafe Object.invoke(context, arguments) },
            { context in unsafe Object.releaseCallback(context) },
        )
        return unsafe try take(function, in: attachment)
    }

    private static func invoke(
        _ context: UnsafeMutableRawPointer?,
        _ arguments: UnsafeMutablePointer<PyObject>?,
    ) -> UnsafeMutablePointer<PyObject>? {
        guard let context = unsafe context, let argumentsPointer = unsafe arguments else {
            Object.raise(Failure("Missing Swift callback arguments."))
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

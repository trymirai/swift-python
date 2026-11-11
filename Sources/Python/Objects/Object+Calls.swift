//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    @_lifetime(copy self)
    borrowing func call() throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        return unsafe try Self.take(PyObject_CallNoArgs(pointer), inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func call<T: Encodable>(_ argument: T) throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        let object = try Object(encoding: argument, in: self)
        return try call(object)
    }

    /// Calls a Python callable with positional and keyword arguments.
    @_lifetime(copy self)
    borrowing func call(
        arguments: [any Encodable],
        keywords: [(String, any Encodable)],
    ) throws -> Object {
        if keywords.isEmpty {
            switch arguments.count {
            case 0:
                return try call()
            case 1:
                return try call(arguments[0])
            default:
                break
            }
        }

        _ = try Interpreter.Storage.requireCurrent()

        let positional = try positionalArguments(arguments)
        if keywords.isEmpty {
            return try call(positional: positional)
        }

        let named = try keywordArguments(keywords)
        return unsafe try Self.take(
            PyObject_Call(pointer, positional.pointer, named.pointer),
            inheriting: self,
        )
    }
}

extension Object {
    @_lifetime(copy self)
    borrowing func item(at index: Int) throws -> Object {
        let item = unsafe try Self.require(
            PyTuple_GetItem(pointer, index),
            "Unable to read the Python tuple.",
        )
        return unsafe Self.retaining(item, inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func call(_ argument: borrowing Object) throws -> Object {
        unsafe try Self.take(PyObject_CallOneArg(pointer, argument.pointer), inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func call(_ first: borrowing Object, _ second: borrowing Object) throws -> Object {
        let arguments = unsafe try Self.take(PyTuple_New(2), in: self)
        try arguments.setTupleItem(first.retained(), at: 0)
        try arguments.setTupleItem(second.retained(), at: 1)

        return try call(positional: arguments)
    }

    @_lifetime(copy self)
    borrowing func call(
        _ first: borrowing Object,
        _ second: borrowing Object,
        _ third: borrowing Object,
    ) throws -> Object {
        unsafe try Self.take(
            CPython_Call3(pointer, first.pointer, second.pointer, third.pointer),
            inheriting: self,
        )
    }

    @_lifetime(copy self)
    private borrowing func call(positional arguments: borrowing Object) throws -> Object {
        unsafe try Self.take(PyObject_CallObject(pointer, arguments.pointer), inheriting: self)
    }

    @_lifetime(borrow self)
    private borrowing func positionalArguments(_ arguments: [any Encodable]) throws -> Object {
        let tuple = unsafe try Self.take(PyTuple_New(arguments.count), in: self)
        for (index, argument) in arguments.enumerated() {
            try tuple.setTupleItem(Object(encoding: argument, in: self), at: index)
        }

        return tuple
    }

    @_lifetime(borrow self)
    private borrowing func keywordArguments(
        _ keywords: [(String, any Encodable)],
    ) throws -> Object {
        let dictionary = unsafe try Self.take(PyDict_New(), in: self)
        for (name, value) in keywords {
            try dictionary.set(value, forKey: name)
        }

        return dictionary
    }

    private borrowing func setTupleItem(_ value: consuming Object, at index: Int) throws {
        // PyTuple_SetItem steals the reference even if it fails.
        try Self.check(
            unsafe PyTuple_SetItem(pointer, index, value.release()),
            "Unable to build Python call arguments.",
        )
    }
}

extension Object {
    @_lifetime(borrow self)
    @unsafe
    borrowing func callInterruptibly(
        _ arguments: [UnsafeMutablePointer<PyObject>],
        using execution: Session.Control,
    ) throws -> Object {
        let context = unsafe Unmanaged.passUnretained(execution).toOpaque()

        execution.beginEvaluation(in: CPython_InterpreterKey(nil))
        defer {
            execution.endEvaluation()
            withExtendedLifetime(execution) {}
        }

        let result = arguments.withUnsafeBufferPointer { arguments in
            unsafe CPython_CallInterruptibly(
                pointer,
                arguments.baseAddress,
                arguments.count,
                context,
                { context in unsafe Object.interrupt(context) },
            )
        }
        return unsafe try Self.take(result, in: self)
    }

    static func interrupt(_ context: UnsafeMutableRawPointer?) -> Bool {
        guard let context = unsafe context else {
            return false
        }
        return unsafe Unmanaged<Session.Control>.fromOpaque(context)
            .takeUnretainedValue()
            .deliverInterruption()
    }
}

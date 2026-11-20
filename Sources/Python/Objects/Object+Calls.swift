//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    @_lifetime(copy self)
    borrowing func callAsFunction() throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        return try callWithoutArguments()
    }

    @_lifetime(copy self)
    borrowing func callAsFunction<T: Encodable & ~Copyable>(
        _ argument: borrowing T,
    ) throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        let object = try Object(encoding: argument, in: self)
        return try callOneArgument(object)
    }

    @_lifetime(copy self)
    borrowing func callAsFunction(
        _ argument: borrowing Object,
    ) throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        return try callOneArgument(argument)
    }

    @_lifetime(copy self)
    borrowing func callAsFunction(
        _ first: borrowing Object,
        _ second: borrowing Object,
    ) throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        return unsafe try Self.take(
            CPython_Call2(pointer, first.pointer, second.pointer),
            inheriting: self,
        )
    }

    /// Looks up a bound Python method. Call the returned object to invoke it.
    @_lifetime(copy self)
    borrowing func callAsFunction(methodNamed name: String) throws -> Object {
        try value(forAttribute: name)
    }

    // Prefer the single-value overload so scalar calls can skip the variadic array.
    @_disfavoredOverload
    @_lifetime(copy self)
    borrowing func callAsFunction(
        _ arguments: any Encodable...,
        keywords: [(String, any Encodable)] = [],
    ) throws -> Object {
        try self(arguments: arguments, keywords: keywords)
    }

    /// Calls a Python callable with positional and keyword arguments.
    @_lifetime(copy self)
    borrowing func callAsFunction(
        arguments: [any Encodable],
        keywords: [(String, any Encodable)] = [],
    ) throws -> Object {
        _ = try Interpreter.Storage.requireCurrent()
        switch (arguments.count, keywords.isEmpty) {
        case (0, true):
            return try callWithoutArguments()
        case (1, true):
            return try callOneArgument(Object(encoding: arguments[0], in: self))
        default:
            break
        }

        let positional = try positionalArguments(arguments)
        if keywords.isEmpty {
            return unsafe try call(positional: positional)
        }

        let named = try keywordArguments(keywords)
        return unsafe try call(positional: positional, keywords: named.pointer)
    }
}

extension Object {
    @_lifetime(copy self)
    private borrowing func callWithoutArguments() throws -> Object {
        unsafe try Self.take(PyObject_CallNoArgs(pointer), inheriting: self)
    }

    @_lifetime(copy self)
    private borrowing func callOneArgument(_ argument: borrowing Object) throws -> Object {
        unsafe try Self.take(PyObject_CallOneArg(pointer, argument.pointer), inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func callAsFunction(
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
    @unsafe
    private borrowing func call(
        positional arguments: borrowing Object,
        keywords: UnsafeMutablePointer<PyObject>? = nil,
    ) throws -> Object {
        unsafe try Self.take(
            PyObject_Call(pointer, arguments.pointer, keywords),
            inheriting: self,
        )
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
            try dictionary.addKeyword(name, value: value)
        }

        return dictionary
    }

    private borrowing func addKeyword(_ name: String, value: any Encodable) throws {
        let key = try Object(encoding: name, in: self)
        let present = unsafe PyDict_Contains(pointer, key.pointer)
        guard present >= 0 else {
            throw Self.failure("Unable to check a Python keyword.")
        }
        guard present == 0 else {
            throw Failure(.typeError, message: "Repeated keyword argument '\(name)'.")
        }

        let value = try Object(encoding: value, in: self)
        try Self.check(
            unsafe PyDict_SetItem(pointer, key.pointer, value.pointer),
            "Unable to set a Python keyword.",
        )
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
        let control = unsafe Unmanaged<Session.Control>.fromOpaque(context).takeUnretainedValue()
        return control.deliverInterruption()
    }
}

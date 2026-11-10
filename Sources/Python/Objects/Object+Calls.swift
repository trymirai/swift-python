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

        return unsafe try Self.take(
            PyObject_CallObject(pointer, arguments.pointer),
            inheriting: self,
        )
    }

    private borrowing func setTupleItem(_ value: consuming Object, at index: Int) throws {
        try Self.check(
            unsafe PyTuple_SetItem(pointer, index, value.release()),
            "Unable to build Python call arguments.",
        )
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

    private static func interrupt(_ context: UnsafeMutableRawPointer?) -> Bool {
        guard let context = unsafe context else {
            return false
        }
        return unsafe Unmanaged<Session.Control>.fromOpaque(context)
            .takeUnretainedValue()
            .deliverInterruption()
    }
}

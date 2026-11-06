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
    borrowing func evaluate<Source: Encodable>(
        _ source: borrowing Source,
        filename: String? = nil,
        execution: Session.Control,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let source = try Object(encoding: source, in: attachment)
        let filename = try Object(encoding: filename, in: attachment)
        let control = try Object.makeFunction(execution, in: attachment)

        let context = unsafe Unmanaged.passUnretained(execution).toOpaque()
        defer {
            withExtendedLifetime(execution) {}
        }
        return unsafe try Self.take(CPython_Evaluate(
            pointer,
            source.pointer,
            filename.pointer,
            control.pointer,
            context,
            { context in unsafe Object.interrupt(context) },
        ), in: self)
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

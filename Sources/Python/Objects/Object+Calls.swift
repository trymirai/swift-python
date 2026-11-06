//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    @_lifetime(copy self)
    borrowing func call() throws -> Object {
        _ = try InterpreterStorage.requireCurrent()
        return unsafe try Self.take(PyObject_CallNoArgs(pointer), inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func call<T: Encodable>(_ argument: T) throws -> Object {
        _ = try InterpreterStorage.requireCurrent()
        let object = try Object(encoding: argument, in: self)
        return try call(object)
    }
}

extension Object {
    @_lifetime(copy self)
    borrowing func item(at index: Int) throws -> Object {
        guard let item = unsafe PyTuple_GetItem(pointer, index) else {
            throw Self.failure("Unable to read the Python tuple.")
        }
        unsafe Py_IncRef(item)
        return unsafe try Self.take(item, inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func call(_ argument: borrowing Object) throws -> Object {
        unsafe try Self.take(PyObject_CallOneArg(pointer, argument.pointer), inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func call(_ first: borrowing Object, _ second: borrowing Object) throws -> Object {
        let arguments = unsafe try Self.take(PyTuple_New(2), in: self)
        unsafe Py_IncRef(first.pointer)
        guard unsafe PyTuple_SetItem(arguments.pointer, 0, first.pointer) == 0 else {
            throw Self.failure("Unable to build Python call arguments.")
        }
        unsafe Py_IncRef(second.pointer)
        guard unsafe PyTuple_SetItem(arguments.pointer, 1, second.pointer) == 0 else {
            throw Self.failure("Unable to build Python call arguments.")
        }
        return unsafe try Self.take(
            PyObject_CallObject(pointer, arguments.pointer),
            inheriting: self,
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
        execution: ExecutionControl,
        in attachment: borrowing ThreadState.Attachment,
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
        return unsafe Unmanaged<ExecutionControl>.fromOpaque(context)
            .takeUnretainedValue()
            .deliverInterruption()
    }
}

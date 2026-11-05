//
//  Created by Anton Spivak
//

internal import libcpython

public extension Object {
    subscript(_ key: String) -> Item {
        @_lifetime(borrow self)
        get { unsafe Item(container: pointer, key: .string(key), in: self) }
    }

    subscript(_ index: Int) -> Item {
        @_lifetime(borrow self)
        get { unsafe Item(container: pointer, key: .index(index), in: self) }
    }

    @_lifetime(copy self)
    borrowing func call() throws -> Object {
        _ = try InterpreterStorage.requireCurrent()
        return unsafe try Self.take(PyObject_CallNoArgs(pointer), inheriting: self)
    }

    @_lifetime(copy self)
    borrowing func call<T: Encodable>(_ argument: T) throws -> Object {
        _ = try InterpreterStorage.requireCurrent()
        let argument = try Object(encoding: argument, in: self)
        return unsafe try Self.take(
            PyObject_CallOneArg(pointer, argument.pointer),
            inheriting: self,
        )
    }
}

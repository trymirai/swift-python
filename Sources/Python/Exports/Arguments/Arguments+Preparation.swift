//
//  Created by Anton Spivak
//

internal import libcpython

public extension Arguments {
    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: UTF8Span.Type,
        parameter: Int,
    ) throws -> some _PythonArgument<UTF8Span> & ~Copyable & ~Escapable {
        do {
            _ = try InterpreterStorage.requireCurrent()
            let pointer = unsafe try element(position(parameter))
            var count = 0
            guard let start = unsafe PyUnicode_AsUTF8AndSize(pointer, &count) else {
                throw Object.failure("Expected a Python string.")
            }
            unsafe Py_IncRef(pointer)
            let object = unsafe Object(owned: pointer, in: self)
            return unsafe UTF8Argument(
                owner: consume object,
                start: UnsafeRawPointer(start)
                    .assumingMemoryBound(to: UInt8.self),
                count: count,
            )
        } catch {
            return unsafe UTF8Argument(owner: nil, start: nil, count: 0, error: error)
        }
    }

    @_documentation(visibility: internal)
    borrowing func prepare<T: Decodable & ~Copyable>(
        _ type: T.Type,
        parameter: Int,
    ) throws -> some _PythonArgument<T> & ~Copyable {
        do {
            let value = try get(position(parameter), as: type)
            return PreparedValue(value: .some(consume value))
        } catch {
            return PreparedValue<T>(value: nil, error: error)
        }
    }

    @_documentation(visibility: internal)
    borrowing func prepare<T: Decodable & ~Copyable>(
        _ type: T.Type,
        parameter: Int,
        default makeDefault: () throws -> T,
    ) throws -> some _PythonArgument<T> & ~Copyable {
        do {
            let index = try position(parameter)
            let value = try isMissing(index) ? makeDefault() : get(index, as: type)
            return PreparedValue(value: .some(consume value))
        } catch {
            return PreparedValue<T>(value: nil, error: error)
        }
    }

    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: Context.Type,
        parameter: Int,
    ) throws -> some _PythonArgument<Context> & ~Copyable & ~Escapable {
        do {
            let value = try Context(in: self)
            return PreparedValue(value: .some(consume value))
        } catch {
            return PreparedValue<Context>(value: nil, error: error)
        }
    }

    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: Object.Type,
        parameter: Int,
    ) throws -> some _PythonArgument<Object> & ~Copyable & ~Escapable {
        do {
            let pointer = unsafe try element(position(parameter))
            unsafe Py_IncRef(pointer)
            let value = unsafe Object(owned: pointer, in: self)
            return PreparedValue(value: .some(consume value))
        } catch {
            return PreparedValue<Object>(value: nil, error: error)
        }
    }

    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: BorrowedObject.Type,
        parameter: Int,
    ) throws -> some _PythonArgument<BorrowedObject> & ~Copyable & ~Escapable {
        do {
            let value = unsafe try BorrowedObject(element(position(parameter)), in: self)
            return PreparedValue(value: value)
        } catch {
            return PreparedValue<BorrowedObject>(value: nil, error: error)
        }
    }
}

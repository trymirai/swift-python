//
//  Created by Anton Spivak
//

public extension Arguments {
    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: UTF8Span.Type,
        parameter: Int,
    ) throws -> some _PArgument<UTF8Span> & ~Copyable & ~Escapable {
        do {
            _ = try Interpreter.Storage.requireCurrent()
            let pointer = unsafe try element(position(parameter))
            guard let bytes = unsafe Object.utf8Buffer(pointer) else {
                throw Object.failure("Expected a Python string.")
            }
            let object = unsafe Object.retaining(pointer, in: self)
            let view = unsafe Arguments.PreparedUTF8.View(owner: consume object, bytes: bytes)
            return Arguments.PreparedUTF8(.ready(consume view))
        } catch {
            return Arguments.PreparedUTF8(.failed(error))
        }
    }

    @_documentation(visibility: internal)
    borrowing func prepare<T: Decodable & ~Copyable>(
        _ type: T.Type,
        parameter: Int,
    ) throws -> some _PArgument<T> & ~Copyable {
        Arguments.PreparedValue<T> {
            try withArgument(type, parameter: parameter) { consume $0 }
        }
    }

    @_documentation(visibility: internal)
    borrowing func prepare<T: Decodable & ~Copyable>(
        _ type: T.Type,
        parameter: Int,
        default makeDefault: () throws -> T,
    ) throws -> some _PArgument<T> & ~Copyable {
        Arguments.PreparedValue<T> {
            try withArgument(type, parameter: parameter, default: makeDefault) { consume $0 }
        }
    }

    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: Context.Type,
        parameter: Int,
    ) throws -> some _PArgument<Context> & ~Copyable {
        Arguments.PreparedValue<Context> {
            try context(at: parameter)
        }
    }

    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: Object.Type,
        parameter: Int,
    ) throws -> some _PArgument<Object> & ~Copyable & ~Escapable {
        do {
            let value = try ownedArgument(at: parameter)
            return Arguments.PreparedValue.ready(consume value)
        } catch {
            return Arguments.PreparedValue<Object>.failed(error)
        }
    }

    @_lifetime(borrow self)
    @_documentation(visibility: internal)
    borrowing func prepare(
        _ type: BorrowedObject.Type,
        parameter: Int,
    ) throws -> some _PArgument<BorrowedObject> & ~Copyable & ~Escapable {
        do {
            let value = try borrowedArgument(at: parameter)
            return Arguments.PreparedValue.ready(value)
        } catch {
            return Arguments.PreparedValue<BorrowedObject>.failed(error)
        }
    }
}

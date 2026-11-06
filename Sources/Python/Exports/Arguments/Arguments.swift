//
//  Created by Anton Spivak
//

internal import libcpython

/// Python arguments borrowed for one synchronous callback.
@safe
public struct Arguments: ~Copyable, ~Escapable {
    let pointer: UnsafeMutablePointer<PyObject>
    private let argumentIndices: [Int]
    private let count: Int
    private let defaultArgumentMarker: UInt?

    @_lifetime(borrow object)
    init(
        _ object: borrowing Object,
        parameters: [Module.Function.Parameter],
        argumentIndices: [Int],
    ) throws {
        let count = unsafe PyTuple_Size(object.pointer)
        let expected = parameters.count { !$0.isInjected }
        guard count == expected else {
            throw Exception(name: "TypeError", message: "Invalid Swift callback arguments.")
        }

        let defaultArgumentMarker = InterpreterStorage.current()?.defaultArgumentMarker
        for (parameter, index) in zip(parameters, argumentIndices)
            where !parameter.isInjected && !parameter.hasDefaultValue
        {
            guard let value = unsafe PyTuple_GetItem(object.pointer, index) else {
                throw Object.failure("Unable to read Python arguments.")
            }
            if UInt(bitPattern: value) == defaultArgumentMarker {
                throw Exception(
                    name: "TypeError",
                    message: "Missing argument '\(parameter.name)'.",
                )
            }
        }

        self.argumentIndices = argumentIndices
        self.count = count
        self.defaultArgumentMarker = defaultArgumentMarker

        unsafe self.pointer = object.pointer
    }

    public borrowing func isMissing(_ index: Int) throws -> Bool {
        let value = unsafe try element(index)
        return UInt(bitPattern: value) == defaultArgumentMarker
    }

    public borrowing func get<T: Decodable & ~Copyable>(
        _ index: Int,
        as type: T.Type = T.self,
    ) throws -> T {
        let decoder = unsafe try Decoder(element(index), in: self)
        return try decoder.decode(type)
    }

    public borrowing func withArgument<T: Decodable & ~Copyable, Result: ~Copyable>(
        _ type: T.Type,
        parameter: Int,
        _ body: (consuming T) throws -> Result,
    ) throws -> Result {
        try body(get(position(parameter), as: type))
    }

    public borrowing func withArgument<T: Decodable & ~Copyable, Result: ~Copyable>(
        _ type: T.Type,
        parameter: Int,
        default makeDefault: () throws -> T,
        _ body: (consuming T) throws -> Result,
    ) throws -> Result {
        let index = try position(parameter)
        return try body(isMissing(index) ? makeDefault() : get(index, as: type))
    }

    public borrowing func withArgument<Result: ~Copyable>(
        _ type: Context.Type,
        parameter: Int,
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        let context = try Context()
        return try body(context)
    }

    public borrowing func withArgument<Result: ~Copyable>(
        _ type: Object.Type,
        parameter: Int,
        _ body: (borrowing Object) throws -> Result,
    ) throws -> Result {
        let value = unsafe try element(position(parameter))
        unsafe Py_IncRef(value)
        let object = unsafe Object(owned: value, in: self)
        return try body(object)
    }

    public borrowing func withArgument<Result: ~Copyable>(
        _ type: BorrowedObject.Type,
        parameter: Int,
        _ body: (BorrowedObject) throws -> Result,
    ) throws -> Result {
        let object = unsafe try BorrowedObject(element(position(parameter)), in: self)
        return try body(object)
    }

    func position(_ parameter: Int) throws -> Int {
        guard argumentIndices.indices.contains(parameter) else {
            throw Exception(name: "TypeError", message: "Invalid Swift parameter index.")
        }
        return argumentIndices[parameter]
    }

    @unsafe
    borrowing func element(_ index: Int) throws -> UnsafeMutablePointer<PyObject> {
        guard
            index >= 0, index < count,
            let value = unsafe PyTuple_GetItem(pointer, index)
        else {
            throw Exception(name: "TypeError", message: "Invalid Python argument index.")
        }
        return unsafe value
    }
}

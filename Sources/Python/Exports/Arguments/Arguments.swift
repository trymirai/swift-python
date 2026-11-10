//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Arguments

/// Python arguments borrowed for one synchronous callback.
@safe
public struct Arguments: ~Copyable, ~Escapable {
    let pointer: UnsafeMutablePointer<PyObject>

    private let layout: Layout
    private let defaultArgumentMarker: UInt?

    @_lifetime(borrow object)
    init(_ object: borrowing Object, layout: Layout) throws {
        let count = unsafe PyTuple_Size(object.pointer)
        guard count >= 0 else {
            throw Object.failure("Expected a Python argument tuple.")
        }
        guard count == layout.count else {
            throw Exception(name: "TypeError", message: "Invalid Swift callback arguments.")
        }

        let marker = Interpreter.Storage.current()?.defaultArgumentMarker
        try Self.validateRequiredArguments(in: object, layout: layout, marker: marker)

        self.layout = layout
        self.defaultArgumentMarker = marker
        unsafe self.pointer = object.pointer
    }

    private static func validateRequiredArguments(
        in object: borrowing Object,
        layout: Layout,
        marker: UInt?,
    ) throws {
        // Required arguments must be present before the generated binder evaluates defaults.
        for case let .argument(index, parameter) in layout.slots
            where parameter.defaultValue.isRequired
        {
            let value = unsafe try Object.require(
                PyTuple_GetItem(object.pointer, index),
                "Unable to read Python arguments.",
            )
            if UInt(bitPattern: value) == marker {
                throw Exception(
                    name: "TypeError",
                    message: "Missing argument '\(parameter.name)'.",
                )
            }
        }
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
        try body(context(at: parameter))
    }

    public borrowing func withArgument<Result: ~Copyable>(
        _ type: Object.Type,
        parameter: Int,
        _ body: (borrowing Object) throws -> Result,
    ) throws -> Result {
        try body(ownedArgument(at: parameter))
    }

    public borrowing func withArgument<Result: ~Copyable>(
        _ type: BorrowedObject.Type,
        parameter: Int,
        _ body: (BorrowedObject) throws -> Result,
    ) throws -> Result {
        try body(borrowedArgument(at: parameter))
    }

    @_lifetime(borrow self)
    borrowing func ownedArgument(at parameter: Int) throws -> Object {
        let value = unsafe try element(position(parameter))
        return unsafe Object.retaining(value, in: self)
    }

    @_lifetime(borrow self)
    borrowing func borrowedArgument(at parameter: Int) throws -> BorrowedObject {
        unsafe try BorrowedObject(element(position(parameter)), in: self)
    }

    func position(_ parameter: Int) throws -> Int {
        guard case let .argument(index, _)? = slot(at: parameter) else {
            throw Exception(
                name: "TypeError",
                message: "Expected a Python argument at Swift parameter \(parameter).",
            )
        }
        return index
    }

    func context(at parameter: Int) throws -> Context {
        guard case .context? = slot(at: parameter) else {
            throw Exception(name: "TypeError", message: "Expected an injected Python context.")
        }
        return try Context()
    }

    private func slot(at parameter: Int) -> Layout.Slot? {
        layout.slots.indices.contains(parameter) ? layout.slots[parameter] : nil
    }

    @unsafe
    borrowing func element(_ index: Int) throws -> UnsafeMutablePointer<PyObject> {
        guard index >= 0, index < layout.count else {
            throw Exception(name: "TypeError", message: "Invalid Python argument index.")
        }
        return unsafe try Object.require(
            PyTuple_GetItem(pointer, index),
            "Unable to read a Python argument.",
        )
    }
}

// MARK: Arguments.Layout

extension Arguments {
    struct Layout: Sendable {
        let slots: [Slot]
        let count: Int

        init(_ parameters: [Module.Function.Parameter]) {
            var position = 0
            slots = parameters.map { parameter in
                if parameter.isInjected {
                    return .context
                }
                defer { position += 1 }
                return .argument(position, parameter)
            }
            count = position
        }
    }
}

// MARK: - Arguments.Layout.Slot

extension Arguments.Layout {
    enum Slot: Sendable {
        case context
        case argument(Int, Module.Function.Parameter)
    }
}

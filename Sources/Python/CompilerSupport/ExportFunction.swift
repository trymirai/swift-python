//
//  Created by Anton Spivak
//

@_documentation(visibility: internal)
public struct _ExportFunction: Sendable {
    public typealias AsyncOperation = @Sendable () async throws -> any Encodable & Sendable

    enum Body: Sendable {
        case synchronous(
            @Sendable (
                borrowing Object,
                inout Encoder,
            ) throws -> Void,
        )

        case asynchronous(
            @Sendable (
                borrowing Object,
            ) throws -> AsyncOperation,
        )
    }

    let name: String
    let documentation: String?
    let parameters: [Parameter]

    let returnAnnotation: String?
    let usesSwiftBinding: Bool

    let body: Body

    package init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returnAnnotation: String? = nil,
        call: @escaping @Sendable (
            borrowing Arguments,
            borrowing Context,
            inout Encoder,
        ) throws -> Void,
    ) {
        let indices = Self.makeArgumentIndices(for: parameters)
        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: returnAnnotation,
            usesSwiftBinding: true,
            body: .synchronous { tuple, encoder in
                let arguments = try Arguments(
                    tuple,
                    parameters: parameters,
                    argumentIndices: indices,
                )
                let context = try Context()
                try call(arguments, context, &encoder)
            },
        )
    }

    package init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returnAnnotation: String? = nil,
        start: @escaping @Sendable (
            borrowing Arguments,
            borrowing Context,
        ) throws -> AsyncOperation,
    ) {
        let indices = Self.makeArgumentIndices(for: parameters)
        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: returnAnnotation,
            usesSwiftBinding: true,
            body: .asynchronous { tuple in
                let arguments = try Arguments(
                    tuple,
                    parameters: parameters,
                    argumentIndices: indices,
                )
                let context = try Context()
                return try start(arguments, context)
            },
        )
    }

    package init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returnAnnotation: String? = nil,
        body: @escaping @Sendable ([Value]) async throws -> Value,
    ) {
        let count = parameters.count
        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: returnAnnotation,
            usesSwiftBinding: false,
            body: .asynchronous { tuple in
                let values = try Self.values(in: tuple, count: count)
                return { try await body(values) }
            },
        )
    }

    package init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returnAnnotation: String? = nil,
        synchronous body: @escaping @Sendable ([Value]) throws -> Value,
    ) {
        let count = parameters.count
        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: returnAnnotation,
            usesSwiftBinding: false,
            body: .synchronous { tuple, encoder in
                try encoder.encode(body(Self.values(in: tuple, count: count)))
            },
        )
    }

    public static func makeOperation<Result: Encodable & Sendable>(
        _ body: @escaping @Sendable () async throws -> Result,
    ) -> AsyncOperation {
        { try await body() }
    }

    public static func makeOperation(
        _ body: @escaping @Sendable () async throws -> Void,
    ) -> AsyncOperation {
        {
            try await body()
            return Value.none
        }
    }

    public init<Result: ~Copyable & ~Escapable>(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returning: Result.Type,
        call: @escaping @Sendable (
            borrowing Arguments,
            borrowing Context,
            inout Encoder,
        ) throws -> Void,
    ) {
        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: pythonAnnotation(returning),
            call: call,
        )
    }

    public init<Result: ~Copyable & ~Escapable>(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returning: Result.Type,
        start: @escaping @Sendable (
            borrowing Arguments,
            borrowing Context,
        ) throws -> AsyncOperation,
    ) {
        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: pythonAnnotation(returning),
            start: start,
        )
    }

    private init(
        _ name: String,
        documentation: String?,
        parameters: [Parameter],
        returnAnnotation: String?,
        usesSwiftBinding: Bool,
        body: Body,
    ) {
        self.name = name
        self.documentation = documentation
        self.parameters = parameters
        self.returnAnnotation = returnAnnotation
        self.usesSwiftBinding = usesSwiftBinding
        self.body = body
    }

    private static func values(in tuple: borrowing Object, count: Int) throws -> [Value] {
        guard case let .list(values) = try tuple.value(), values.count == count else {
            throw Exception(name: "TypeError", message: "Invalid Swift callback arguments.")
        }
        return values
    }

    private static func makeArgumentIndices(for parameters: [Parameter]) -> [Int] {
        var indices = [Int]()
        indices.reserveCapacity(parameters.count)
        var nextIndex = 0
        for parameter in parameters {
            indices.append(nextIndex)
            if !parameter.isInjected {
                nextIndex += 1
            }
        }
        return indices
    }
}

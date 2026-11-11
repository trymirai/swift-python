//
//  Created by Anton Spivak
//

// MARK: - _ExportFunction

@_documentation(visibility: internal)
public struct _ExportFunction: Sendable {
    public typealias AsyncOperation = @Sendable () async throws -> any Encodable & Sendable

    let name: String
    let documentation: String?

    let parameters: [Parameter]
    let returnAnnotation: Annotation?

    let usesSwiftBinding: Bool
    let body: Body

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

    private init(
        _ name: String,
        documentation: String?,
        parameters: [Parameter],
        returnAnnotation: Annotation?,
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
}

// MARK: _ExportFunction + Swift argument binding

extension _ExportFunction {
    public init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returning: Annotation,
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
            returnAnnotation: returning,
            call: call,
        )
    }

    public init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returning: Annotation,
        start: @escaping @Sendable (
            borrowing Arguments,
            borrowing Context,
        ) throws -> AsyncOperation,
    ) {
        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: returning,
            start: start,
        )
    }

    package init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returnAnnotation: Annotation? = nil,
        call: @escaping @Sendable (
            borrowing Arguments,
            borrowing Context,
            inout Encoder,
        ) throws -> Void,
    ) {
        let layout = Arguments.Layout(parameters)

        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: returnAnnotation,
            usesSwiftBinding: true,
            body: .synchronous { tuple, encoder in
                let arguments = try Arguments(tuple, layout: layout)
                let context = try Context()
                try call(arguments, context, &encoder)
            },
        )
    }

    package init(
        _ name: String,
        documentation: String? = nil,
        parameters: [Parameter] = [],
        returnAnnotation: Annotation? = nil,
        start: @escaping @Sendable (
            borrowing Arguments,
            borrowing Context,
        ) throws -> AsyncOperation,
    ) {
        let layout = Arguments.Layout(parameters)

        self.init(
            name,
            documentation: documentation,
            parameters: parameters,
            returnAnnotation: returnAnnotation,
            usesSwiftBinding: true,
            body: .asynchronous { tuple in
                let arguments = try Arguments(tuple, layout: layout)
                let context = try Context()
                return try start(arguments, context)
            },
        )
    }
}

// MARK: _ExportFunction + Value argument binding

package extension _ExportFunction {
    init(
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
            returnAnnotation: returnAnnotation.map { Annotation(text: $0) },
            usesSwiftBinding: false,
            body: .asynchronous { tuple in
                let values = try Self.values(in: tuple, count: count)
                return { try await body(values) }
            },
        )
    }

    init(
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
            returnAnnotation: returnAnnotation.map { Annotation(text: $0) },
            usesSwiftBinding: false,
            body: .synchronous { tuple, encoder in
                let values = try Self.values(in: tuple, count: count)
                try encoder.encode(body(values))
            },
        )
    }

    private static func values(in tuple: borrowing Object, count: Int) throws -> [Value] {
        guard case let .list(values) = try tuple.value(), values.count == count else {
            throw Exception(name: "TypeError", message: "Invalid Swift callback arguments.")
        }
        return values
    }
}

// MARK: _ExportFunction.Body

extension _ExportFunction {
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
}

// MARK: _ExportFunction.ID

extension _ExportFunction {
    struct ID {
        let rawValue: Int
    }
}

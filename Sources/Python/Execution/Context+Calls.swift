//
//  Created by Anton Spivak
//

public extension Context {
    /// Calls Python from the active Swift export and awaits the result if it is awaitable.
    func call<Result: Decodable & Sendable & ~Copyable>(
        _ function: Reference,
        arguments: [any Encodable & Sendable] = [],
        keywords: [(String, any Encodable & Sendable)] = [],
        as type: Result.Type = Result.self,
    ) async throws -> Result {
        try Task.checkCancellation()
        try checkExecution()

        let call = ImportedCall<Session.Transfer<Result>>(
            .instance(function),
            arguments: arguments,
            keywords: keywords,
            as: type,
        )
        guard let invocation else {
            throw Failure.closed
        }

        return try await call.value(during: invocation.callback()).take()
    }

    /// Calls an imported class method in this context.
    func call<Type: _PImported, Result: Decodable & ~Copyable>(
        _ type: Type.Type,
        method name: String,
        arguments: [any Encodable] = [],
        keywords: [(String, any Encodable)] = [],
        as result: Result.Type = Result.self,
    ) throws -> Result {
        try withAccess { context in
            let object = try type.pythonClass(in: context)
            return try Self.invoke(
                name,
                on: object,
                arguments: arguments,
                keywords: keywords,
                as: result,
            )
        }
    }

    /// Calls a Python instance method in this context.
    func call<Instance: Encodable & ~Copyable, Result: Decodable & ~Copyable>(
        _ instance: borrowing Instance,
        method name: String,
        arguments: [any Encodable] = [],
        keywords: [(String, any Encodable)] = [],
        as result: Result.Type = Result.self,
    ) throws -> Result {
        try withAccess { context in
            let object = try context.encode(instance)
            return try Self.invoke(
                name,
                on: object,
                arguments: arguments,
                keywords: keywords,
                as: result,
            )
        }
    }
}

private extension Context {
    static func invoke<Result: Decodable & ~Copyable>(
        _ name: String,
        on receiver: borrowing Object,
        arguments: [any Encodable],
        keywords: [(String, any Encodable)],
        as type: Result.Type,
    ) throws -> Result {
        try receiver(methodNamed: name)(arguments: arguments, keywords: keywords).decode(as: type)
    }
}

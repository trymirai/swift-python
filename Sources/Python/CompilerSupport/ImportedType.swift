//
//  Created by Anton Spivak
//

// MARK: - _PImported

@_documentation(visibility: internal)
public protocol _PImported {
    static var _pImport: (module: String, name: String) { get }
}

public extension _PImported where Self: Encodable {
    /// Opens this binding as a local Python object in the supplied context.
    @_lifetime(borrow context)
    borrowing func object(in context: borrowing Context) throws -> Object {
        try context.encode(self)
    }
}

public extension _PImported where Self: Decodable {
    @_documentation(visibility: internal)
    static func _pConstruct(
        inContext context: Context,
        arguments: [any Encodable],
        keywords: [(String, any Encodable)],
    ) throws -> Self {
        try context.withAccess { context in
            let constructor = try pythonClass(in: context)
            return try constructor(arguments: arguments, keywords: keywords).decode(as: Self.self)
        }
    }

    @_documentation(visibility: internal)
    static func _pConstruct(
        inSession session: Session,
        arguments: [any Encodable & Sendable],
        keywords: [(String, any Encodable & Sendable)],
    ) async throws -> Self where Self: Sendable {
        let call = ImportedCall<Session.Transfer<Self>>(
            .imported(Self.self),
            arguments: arguments,
            keywords: keywords,
            as: Self.self,
        )
        return try await call.value(in: session).take()
    }
}

public extension _PImported {
    @_documentation(visibility: internal)
    static func _pCallMethod<Result: ~Copyable>(
        _ name: String,
        arguments: [any Encodable],
        keywords: [(String, any Encodable)],
        decode: (borrowing Object) throws -> Result,
    ) throws -> Result {
        try CurrentContext.run { context in
            let type = try pythonClass(in: context)
            return try decode(type(methodNamed: name)(arguments: arguments, keywords: keywords))
        }
    }

    @_documentation(visibility: internal)
    static func _pGetClassProperty<Value: Decodable & ~Copyable>(
        _ name: String,
        as type: Value.Type = Value.self,
    ) throws -> Value {
        try CurrentContext.run { context in
            try pythonClass(in: context).value(forAttribute: name).decode(as: type)
        }
    }

    @_documentation(visibility: internal)
    static func _pSetClassProperty<Value: Encodable & ~Copyable>(
        _ value: borrowing Value,
        forKey name: String,
    ) throws {
        try CurrentContext.run { context in
            try pythonClass(in: context).set(value, forAttribute: name)
        }
    }

    /// Verifies the imported class before retaining the decoded instance.
    @_documentation(visibility: internal)
    static func _pDecodeReference(from decoder: borrowing Decoder) throws -> Reference {
        let object = try decoder.object()
        try requireInstance(object)

        return try Reference(from: decoder)
    }

    @_lifetime(borrow owner)
    internal static func pythonClass<Owner: ~Copyable & ~Escapable>(
        in owner: borrowing Owner,
    ) throws -> Object {
        try Object.importClass(module: _pImport.module, name: _pImport.name, in: owner)
    }

    internal static func requireInstance(_ object: borrowing Object) throws {
        guard try object.isInstance(of: pythonClass(in: object)) else {
            let (module, name) = _pImport
            throw Failure(
                .typeError,
                message: "Expected an instance of \(module).\(name).",
            )
        }
    }
}

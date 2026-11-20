//
//  Created by Anton Spivak
//

public extension Context {
    borrowing func get<T: Decodable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
    ) throws -> T {
        let namespace = try namespace()
        return try namespace.item(.name(name)).get(as: type)
    }

    borrowing func set<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forKey name: String,
    ) throws {
        let namespace = try namespace()
        try namespace.item(.name(name)).set(value)
    }

    borrowing func remove(_ name: String) throws {
        let namespace = try namespace()
        try namespace.item(.name(name)).remove()
    }

    @_lifetime(borrow self)
    borrowing func object(_ name: String) throws -> Object {
        try namespace().value(for: .name(name))
    }

    func get<T: Decodable & Sendable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
    ) async throws -> T {
        try withAccess { try $0.get(name, as: type) }
    }

    func set<T: Encodable & Sendable & ~Copyable>(
        _ value: consuming T,
        forKey name: String,
    ) async throws {
        let transfer = Session.Transfer(consume value)
        try withAccess { context in
            try context.set(transfer.take(), forKey: name)
        }
    }

    func remove(_ name: String) async throws {
        try withAccess { try $0.remove(name) }
    }
}

extension Context {
    @_lifetime(borrow self)
    borrowing func namespace() throws -> Object {
        let storage = try checkAccess()
        if let namespace = storage.namespace {
            return try namespace.resolve(in: self)
        }
        return try Self.currentNamespace(in: self)
    }

    @_lifetime(borrow owner)
    static func currentNamespace<Owner: ~Copyable & ~Escapable>(
        in owner: borrowing Owner,
    ) throws -> Object {
        let module = try Interpreter.executionModule(in: owner)
        return try module(methodNamed: "current_namespace")()
    }
}

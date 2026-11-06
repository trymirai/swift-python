//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Context

/// A binding to one generation of a session's interpreter.
/// Raw Python objects are available while that interpreter is attached.
@safe
public struct Context: Sendable {
    let references: Reference.Store
    private weak var session: Session?

    init(storage: Interpreter.Storage) {
        references = storage.references
        session = storage.session
    }

    init() throws {
        self.init(storage: try Interpreter.Storage.requireCurrent())
    }

    public borrowing func get<T: Decodable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
    ) throws -> T {
        let namespace = try namespace()
        return try namespace.item(.name(name)).get(as: type)
    }

    public borrowing func set<T: Encodable & ~Copyable>(
        _ value: borrowing T,
        forKey name: String,
    ) throws {
        let namespace = try namespace()
        try namespace.item(.name(name)).set(value)
    }

    public borrowing func remove(_ name: String) throws {
        let namespace = try namespace()
        try namespace.item(.name(name)).remove()
    }

    @_lifetime(borrow self)
    public borrowing func object(_ name: String) throws -> Object {
        let namespace = try namespace()
        let value = try namespace.item(.name(name)).object()
        return unsafe _overrideLifetime(consume value, borrowing: self)
    }

    @_lifetime(borrow self)
    public borrowing func object(_ reference: Reference) throws -> Object {
        try reference.resolve(in: self)
    }

    @_lifetime(borrow self)
    public borrowing func object(_ reference: WeakReference) throws -> Object? {
        try reference.resolve(in: self)
    }

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
        return try module.attribute("current_namespace").call()
    }

    @_lifetime(borrow self)
    public borrowing func `import`(module name: String) throws -> Object {
        try checkAccess()
        return try Object.import(module: name, in: self)
    }

    @_lifetime(borrow self)
    public borrowing func encode<T: Encodable & ~Copyable>(_ value: borrowing T) throws -> Object {
        try checkAccess()
        return try Object(encoding: value, in: self)
    }

    public borrowing func checkCancellation() throws {
        try Task.checkCancellation()
        if let storage = Interpreter.Storage.current(), storage.references === references {
            try storage.execution?.checkInterruption()
        }
    }

    @discardableResult
    func checkAccess() throws -> Interpreter.Storage {
        let current = try Interpreter.Storage.requireCurrent()
        guard current.references === references else {
            throw Reference.wrongInterpreter()
        }
        return current
    }

    func requireSession() throws -> Session {
        guard let session else {
            throw Session.Error.closed
        }
        return session
    }
}

public extension Context {
    func get<T: Decodable & Sendable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
    ) async throws -> T {
        try await requireSession().enqueue(in: references) { try $0.get(name, as: type) }
    }

    func set<T: Encodable & Sendable & ~Copyable>(
        _ value: consuming T,
        forKey name: String,
    ) async throws {
        let transfer = Session.Transfer(consume value)
        try await requireSession().enqueue(in: references) {
            try $0.set(transfer.take(), forKey: name)
        }
    }

    func remove(_ name: String) async throws {
        try await requireSession().enqueue(in: references) { try $0.remove(name) }
    }
}

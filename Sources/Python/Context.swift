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

    private weak var execution: Session.Control?

    private(set) weak var streams: Session.Stream.Descriptors?

    init(storage: Interpreter.Storage) {
        references = storage.references
        session = storage.session
        execution = storage.execution
        streams = PThread.Scope.current?.streams
    }

    init() throws {
        self.init(storage: try Interpreter.Storage.requireCurrent())
    }

    /// Swift data for the execution that supplied this context.
    /// The value becomes nil when that execution finishes its callbacks.
    public var scope: (any Sendable)? {
        execution?.scope
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

    func checkExecution() throws {
        guard let execution else {
            throw Session.Error.closed
        }
        try execution.withAccess {}
    }

    func belongs(to session: Session) -> Bool {
        self.session === session
    }
}

public extension Context {
    func get<T: Decodable & Sendable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
    ) async throws -> T {
        try await withSessionContext { try $0.get(name, as: type) }
    }

    func set<T: Encodable & Sendable & ~Copyable>(
        _ value: consuming T,
        forKey name: String,
    ) async throws {
        let transfer = Session.Transfer(consume value)
        try await withSessionContext {
            try $0.set(transfer.take(), forKey: name)
        }
    }

    func remove(_ name: String) async throws {
        try await withSessionContext { try $0.remove(name) }
    }

    private func withSessionContext<Result: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Context) throws -> Result,
    ) async throws -> Result {
        if execution != nil {
            return try withAccess(body)
        }
        return try await requireSession().enqueue(generation: references, body)
    }
}

// MARK: - Context + Attachment

extension Context {
    func withAccess<Result: ~Copyable>(
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        if PThread.Scope.current?.matchesTask == true {
            try checkAccess()
            return try body(self)
        }
        guard let execution else {
            throw Session.Error.closed
        }
        return try execution.withAccess {
            let streams = self.streams
            defer { withExtendedLifetime(streams) {} }
            return try withAttached(body)
        }
    }

    private func withAttached<Result: ~Copyable>(
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        try Task.checkCancellation()
        return unsafe try references.view.withStorage { storage, guardPointer in
            guard storage.references === references else {
                throw Reference.wrongInterpreter()
            }
            return try PThread.Scope
                .run(storage: storage, execution: execution, streams: streams) { scope in
                    try storage.withFileAccess {
                        unsafe try withThreadState(guardedBy: guardPointer) {
                            try withAttachedContext(in: scope, body)
                        }
                    }
                }
        }
    }

    private func withAttachedContext<Result: ~Copyable>(
        in scope: PThread.Scope,
        _ body: (borrowing Context) throws -> Result,
    ) throws -> Result {
        try scope.withEvaluation {
            _ = try Interpreter.Storage.requireCurrent()
            try Task.checkCancellation()
            return try scope.storage.withConstructionScope {
                try body(Context(storage: scope.storage))
            }
        }
    }

    @unsafe
    private func withThreadState<Result: ~Copyable>(
        guardedBy guardPointer: OpaquePointer,
        _ body: () throws -> Result,
    ) throws -> Result {
        guard let token = unsafe PyThreadState_Ensure(guardPointer) else {
            throw Runtime.Failure("Unable to attach to the Python interpreter.")
        }
        defer {
            unsafe PyThreadState_Release(token)
        }
        return try body()
    }
}

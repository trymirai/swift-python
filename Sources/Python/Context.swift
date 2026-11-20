//
//  Created by Anton Spivak
//

// MARK: - Context

/// A binding to one generation of a session's interpreter.
/// Raw Python objects are available while that interpreter is attached.
/// A context supplied to a Swift export expires when that invocation finishes.
@safe
public struct Context: Sendable {
    let references: Reference.Store

    let invocation: Invocation?
    private(set) weak var execution: Session.Control?
    private(set) weak var streams: Session.Stream.Descriptors?

    init(storage: Interpreter.Storage) {
        references = storage.references

        let scope = PThread.Scope.current
        invocation = scope?.invocation
        execution = storage.execution
        streams = scope?.streams
    }

    init() throws {
        self.init(storage: try Interpreter.Storage.requireCurrent())
    }

    /// Data supplied by the host for this execution.
    public var scope: (any Sendable)? {
        guard invocation?.isActive != false else {
            return nil
        }
        return execution?.scope
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
        try invocation?.checkActive()

        let current = try Interpreter.Storage.requireCurrent()
        try current.references.requireSameGeneration(as: references)
        guard let execution, current.execution === execution else {
            throw Failure.closed
        }

        return current
    }

    func requireSession() throws -> Session {
        guard let session = references.session else {
            throw Failure.closed
        }
        return session
    }

    @discardableResult
    func checkExecution() throws -> Session.Control {
        try invocation?.checkActive()

        guard let execution else {
            throw Failure.closed
        }
        try execution.withAccess {}
        return execution
    }

    func belongs(to session: Session) -> Bool {
        references.session === session
    }
}

//
//  Created by Anton Spivak
//

internal import libcpython

/// Access to one attached interpreter. Available only inside a synchronous Python scope.
@safe
public struct Context: ~Copyable, ~Escapable {
    let namespace: UnsafeMutablePointer<PyObject>
    let storage: InterpreterStorage
    private let execution: ExecutionControl?

    @_lifetime(borrow owner)
    init<Owner: ~Copyable & ~Escapable>(
        in owner: borrowing Owner,
        execution: ExecutionControl? = nil,
    ) throws {
        let storage = try InterpreterStorage.requireCurrent()
        let module = try Object.import(module: "_swift_python_runtime.execution", in: owner)
        let function = try module.attribute("current_namespace")
        let namespace = try function.call()
        unsafe self.namespace = namespace.release()
        self.storage = storage
        self.execution = execution ?? storage.execution
    }

    deinit { unsafe InterpreterStorage.release(namespace) }

    public subscript(_ name: String) -> Item {
        @_lifetime(borrow self)
        get { unsafe Item(container: namespace, key: .name(name), in: self) }
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
        try execution?.checkInterruption()
    }

    func checkAccess() throws {
        let current = try InterpreterStorage.requireCurrent()
        guard current === storage else {
            throw Reference.wrongInterpreter()
        }
    }
}

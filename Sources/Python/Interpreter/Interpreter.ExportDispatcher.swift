//
//  Created by Anton Spivak
//

internal import libcpython
internal import SystemPackage

// MARK: - Interpreter.ExportDispatcher

extension Interpreter {
    // Owned by the interpreter's callback capsule. Only owned values enter Swift tasks.
    final class ExportDispatcher {
        private let functions: [Module.Function]

        init(_ functions: [Module.Function]) {
            self.functions = functions
        }

        private func body(for id: Module.Function.ID) throws -> Module.Function.Body {
            guard functions.indices.contains(id.rawValue) else {
                throw Failure(.typeError, message: "Unknown Swift callback.")
            }
            return functions[id.rawValue].body
        }
    }
}

// MARK: - Interpreter.ExportDispatcher + Object.Callable

extension Interpreter.ExportDispatcher: Object.Callable {
    @_lifetime(borrow attachment)
    func call(
        _ request: borrowing Object,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let name = try request.tupleItem(at: 0).string()
        guard let command = Command(rawValue: name) else {
            throw Failure(.valueError, message: "Unknown Swift callback command.")
        }

        let storage = attachment.storage

        func callID() throws -> Session.Control.CallID {
            .init(rawValue: try request.tupleItem(at: 1).decode())
        }

        switch command {
        case .freeze:
            let type = try request.tupleItem(at: 1)
            try Object.check(
                unsafe CPython_FreezeType(type.pointer),
                "Unable to freeze a Python class.",
            )
        case .registerType:
            let key = try request.tupleItem(at: 1).string()
            let type = try request.tupleItem(at: 2)
            try storage.requireClassRegistry().register(type, forKey: key, in: storage)
        case .registerWrapper:
            try storage.requireClassRegistry().registerWrapperFactory(
                request.tupleItem(at: 1),
                in: storage,
            )
        case .bind:
            try storage.requireClassRegistry().bind(request.tupleItem(at: 1))
        case .call, .start:
            return try invokeExport(command, request: request, in: attachment)
        case .poll:
            let callback = try activeExecution().control.export(callID())
            return try poll(callback, in: attachment)
        case .take:
            let id = try callID()
            let result = try activeExecution().control.takeExport(id)
            return try Object(encoding: result, in: attachment)
        case .cancel:
            let id = try callID()
            storage.execution?.cancelExport(id)
        }

        return try Object(encoding: Value.none, in: attachment)
    }

    @_lifetime(borrow attachment)
    private func invokeExport(
        _ command: Command,
        request: borrowing Object,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let id = Module.Function.ID(rawValue: try request.tupleItem(at: 1).decode())
        let arguments = try request.tupleItem(at: 2)

        let (scope, execution) = try activeExecution()
        let invocation = Context.Invocation()
        let previous = exchange(&scope.invocation, with: invocation)
        defer { scope.invocation = previous }

        switch (command, try body(for: id)) {
        case let (.call, .synchronous(invoke)):
            defer { invocation.finish() }
            var encoder = Encoder(in: attachment)
            try CurrentContext.withAttached { try invoke(arguments, &encoder) }
            return unsafe try Object(owned: encoder.take(), in: attachment)
        case let (.start, .asynchronous(prepare)):
            do {
                let operation = try prepare(arguments)
                return try start(
                    operation,
                    during: invocation,
                    scope: scope,
                    execution: execution,
                    in: attachment,
                )
            } catch {
                invocation.finish()
                throw error
            }
        default:
            throw Failure("Invalid Swift callback mode.")
        }
    }

    @_lifetime(borrow attachment)
    private func poll(
        _ callback: Session.Control.ExportCall,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        guard let methods = try callback.poll() else {
            return try Object(encoding: Value.none, in: attachment)
        }

        do {
            return try makeRequests(for: methods, in: attachment)
        } catch {
            methods.forEach { $0.cancel() }
            throw error
        }
    }

    @_lifetime(borrow attachment)
    private func makeRequests(
        for methods: [any ImportedCallRequest],
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let list = unsafe try Object.take(PyList_New(methods.count), in: attachment)
        for (index, method) in methods.enumerated() {
            let function = try Object.makeFunction(method, in: attachment)
            unsafe try Object.setListItem(
                function,
                at: index,
                in: list.pointer,
                failure: "Unable to deliver an imported Python method.",
            )
        }
        return list
    }

    private func activeExecution() throws -> (scope: PThread.Scope, control: Session.Control) {
        guard let scope = PThread.Scope.current, let execution = scope.execution else {
            throw Failure("Swift callbacks require an active Python execution.")
        }
        return (scope, execution)
    }

    @_lifetime(borrow attachment)
    private func start(
        _ operation: @escaping Module.Function.AsyncOperation,
        during invocation: Context.Invocation,
        scope: PThread.Scope,
        execution: Session.Control,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let storage = attachment.storage
        let call = try Session.Control.ExportCall(
            {
                defer { invocation.finish() }
                return try await operation()
            },
            context: Context(storage: storage),
            executor: scope.executorForCallbacks(),
        )
        invocation.bind(call)

        let id = storage.allocateCallID()
        try execution.submit(.export(call), id: id)

        do {
            return try Object(
                encoding: [Int(call.pipe.readDescriptor().rawValue), id.rawValue],
                in: attachment,
            )
        } catch {
            execution.cancelExport(id)
            throw error
        }
    }
}

// MARK: - Interpreter.ExportDispatcher.Command

private extension Interpreter.ExportDispatcher {
    enum Command: String {
        case freeze
        case registerType = "register_type"
        case registerWrapper = "register_wrap"
        case bind

        case call
        case start

        case poll
        case take
        case cancel
    }
}

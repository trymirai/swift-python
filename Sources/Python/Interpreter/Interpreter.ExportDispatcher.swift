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
                throw Exception(name: "TypeError", message: "Unknown Swift callback.")
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
        let name = try request.item(at: 0).string()
        guard let command = Command(rawValue: name) else {
            throw Exception(name: "ValueError", message: "Unknown Swift callback command.")
        }

        let storage = attachment.storage

        func callID() throws -> Session.Control.CallID {
            .init(rawValue: try request.item(at: 1).decode())
        }

        switch command {
        case .freeze:
            let type = try request.item(at: 1)
            try Object.check(
                unsafe CPython_FreezeType(type.pointer),
                "Unable to freeze a Python class.",
            )
        case .registerType:
            let key = try request.item(at: 1).string()
            let type = try request.item(at: 2)
            try classes(in: storage).register(type, forKey: key, in: storage)
        case .registerWrapper:
            try classes(in: storage).registerWrapperFactory(request.item(at: 1), in: storage)
        case .bind:
            try classes(in: storage).bind(request.item(at: 1))
        case .call, .start:
            return try invokeExport(command, request: request, in: attachment)
        case .poll:
            let callback = try execution(in: storage).export(callID())
            return try poll(callback, in: attachment)
        case .take:
            let id = try callID()
            let result = try execution(in: storage).takeExport(id)
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
        let id = Module.Function.ID(rawValue: try request.item(at: 1).decode())
        let arguments = try request.item(at: 2)
        switch (command, try body(for: id)) {
        case let (.call, .synchronous(invoke)):
            var encoder = Encoder(in: attachment)
            try invoke(arguments, &encoder)
            return unsafe try Object(owned: encoder.take(), in: attachment)
        case let (.start, .asynchronous(prepare)):
            return try start(prepare(arguments), in: attachment)
        default:
            throw Runtime.Failure("Invalid Swift callback mode.")
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
        for methods: [any ImportedMethodRequest],
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let list = unsafe try Object.take(PyList_New(methods.count), in: attachment)
        for (index, method) in methods.enumerated() {
            let function = try Object.makeFunction(method, in: attachment)
            try Object.check(
                unsafe PyList_SetItem(list.pointer, index, function.release()),
                "Unable to deliver an imported Python method.",
            )
        }
        return list
    }

    private func classes(in storage: Interpreter.Storage) throws -> Interpreter.ClassRegistry {
        guard let registry = storage.classRegistry else {
            throw Interpreter.ClassRegistry.unregistered()
        }
        return registry
    }

    private func execution(in storage: Interpreter.Storage) throws -> Session.Control {
        guard let execution = storage.execution else {
            throw Runtime.Failure("Swift callbacks require an active Python execution.")
        }
        return execution
    }

    @_lifetime(borrow attachment)
    private func start(
        _ operation: @escaping Module.Function.AsyncOperation,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        let storage = attachment.storage
        let execution = try execution(in: storage)
        let call = try Session.Control.ExportCall(operation, sessionID: storage.sessionOrigin)
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

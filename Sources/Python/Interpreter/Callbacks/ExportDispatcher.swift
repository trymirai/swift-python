//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - ExportDispatcher

// Owned by the interpreter's callback capsule. Only owned values enter Swift tasks.

final class ExportDispatcher {
    private let functions: [Module.Function]

    private var pendingCalls: [Int: AsyncCall] = [:]
    private var nextCallID: Int = 0

    init(_ modules: [Module]) {
        self.functions = modules.flatMap { $0.functions + $0.classes.flatMap(\.functions) }
    }

    deinit { cancelPending() }

    var callBoundary: Int {
        nextCallID
    }

    func cancelPending(since boundary: Int = 0) {
        let callIDs = pendingCalls.keys.filter { $0 >= boundary }
        for callID in callIDs {
            pendingCalls.removeValue(forKey: callID)?.cancel()
        }
    }
}

// MARK: Object.Callable

extension ExportDispatcher: Object.Callable {
    @_lifetime(borrow attachment)
    func call(
        _ request: borrowing Object,
        in attachment: borrowing ThreadState.Attachment,
    ) throws -> Object {
        switch try request.item(at: 0).string() {
        case "freeze":
            let type = try request.item(at: 1)
            guard unsafe CPython_FreezeType(type.pointer) == 0
            else {
                throw Object.failure("Unable to freeze a Python class.")
            }
        case "register_type":
            let key = try request.item(at: 1).string()
            let type = try request.item(at: 2)
            let storage = try InterpreterStorage.requireCurrent()
            guard let registry = storage.classRegistry else {
                throw ExportCatalog.failure("Class registration is closed or invalid.")
            }
            try registry.register(type, forKey: key, in: storage)
        case "register_wrap":
            let storage = try InterpreterStorage.requireCurrent()
            guard let registry = storage.classRegistry else {
                throw ExportCatalog.failure("Python wrapper registration is closed.")
            }
            try registry.registerWrapperFactory(request.item(at: 1), in: storage)
        case "bind":
            try Self.registeredClasses().bind(request.item(at: 1))
        case let command:
            return try dispatchCallback(command, request: request, in: attachment)
        }
        return try Object(encoding: Value.none, in: attachment)
    }

    private static func registeredClasses() throws -> ClassRegistry {
        guard let registry = try InterpreterStorage.requireCurrent().classRegistry else {
            throw ClassRegistry.unregistered()
        }
        return registry
    }

    @_lifetime(borrow attachment)
    private func dispatchCallback(
        _ command: String,
        request: borrowing Object,
        in attachment: borrowing ThreadState.Attachment,
    ) throws -> Object {
        let targetID = try request.item(at: 1).decode(as: Int.self)
        switch command {
        case "call", "start":
            guard functions.indices.contains(targetID) else {
                throw Exception(name: "TypeError", message: "Unknown Swift callback.")
            }

            switch (command, functions[targetID].body) {
            case let ("call", .synchronous(body)):
                let tuple = try request.item(at: 2)
                var encoder = Encoder(in: attachment)
                try body(tuple, &encoder)
                return unsafe try Object(owned: encoder.take(), in: attachment)
            case let ("start", .asynchronous(body)):
                let tuple = try request.item(at: 2)
                return try startCall(body(tuple), in: attachment)
            default:
                throw RuntimeFailure("Invalid Swift callback mode.")
            }
        case "take":
            guard let invocation = pendingCalls.removeValue(forKey: targetID) else {
                throw RuntimeFailure("Unknown Swift callback.")
            }
            var encoder = Encoder(in: attachment)
            try invocation.encode(to: &encoder)
            return unsafe try Object(owned: encoder.take(), in: attachment)
        case "cancel":
            pendingCalls.removeValue(forKey: targetID)?.cancel()
            return try Object(encoding: Value.none, in: attachment)
        default:
            throw Exception(name: "ValueError", message: "Unknown Swift callback command.")
        }
    }

    @_lifetime(borrow attachment)
    private func startCall(
        _ operation: @escaping Module.Function.AsyncOperation,
        in attachment: borrowing ThreadState.Attachment,
    ) throws -> Object {
        let invocation = try AsyncCall(operation: operation)
        let callID = nextCallID
        nextCallID += 1
        pendingCalls[callID] = invocation
        do {
            return try Object(encoding: [Int(invocation.pipe.reader), callID], in: attachment)
        } catch {
            pendingCalls.removeValue(forKey: callID)?.cancel()
            throw error
        }
    }
}

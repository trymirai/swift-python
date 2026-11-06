//
//  Created by Anton Spivak
//

// MARK: - Interpreter

// A session's interpreter and the operations that require its attached thread state.
struct Interpreter: ~Copyable {
    private let pThread: PThread
    private let packagePaths: [String]

    var references: Reference.Store {
        pThread.storage.references
    }

    init(
        execution: Session.Control,
        importPaths: [String],
        modules: [Module],
        packages: [Runtime.PackageSource.Resolved] = [],
        scheduleRelease: @escaping @Sendable () -> Void = {},
        sessionOrigin: ObjectIdentifier? = nil,
        session: Session? = nil,
        delegate: (any Session.Delegate)? = nil,
    ) throws {
        let pThread = try PThread(scheduleRelease: scheduleRelease)
        let storage = pThread.storage

        storage.sessionOrigin = sessionOrigin
        storage.session = session
        storage.fileOpenDelegate = delegate

        let packagePaths = try pThread.withAttached(execution: execution) { attachment in
            try Object.installImporter(in: attachment)
            let packagePaths = try Self.installPackages(packages, in: attachment)

            try Self.configureExecution(importPaths: importPaths + packagePaths, in: attachment)

            try Self.cacheArrayType(in: attachment)
            try Self.installExports(modules, in: attachment)
            return packagePaths
        }

        self.pThread = consume pThread
        self.packagePaths = packagePaths
    }

    borrowing func updateImports(
        paths: [String],
        invalidatingModules modules: [String],
        execution: Session.Control,
    ) throws {
        try pThread.withAttached(execution: execution) { attachment in
            let module = try Object.import(module: "_swift_python_runtime.imports", in: attachment)
            let update = try module.attribute("update_imports")
            _ = try update.call(Object(encoding: [paths + packagePaths, modules], in: attachment))
        }
    }

    borrowing func initialize(
        _ startup: Session.Startup,
        execution: Session.Control,
    ) throws -> Output {
        let output = try execute(
            "initialize",
            source: StartupRequest(value: startup),
            filename: nil,
            execution: execution,
        )
        let storage = pThread.storage
        try pThread.withAttached(execution: execution) { attachment in
            let namespace = try Context.currentNamespace(in: attachment)
            storage.namespace = unsafe try storage.references.retain(namespace.pointer)
        }
        return output
    }

    borrowing func withContext<R: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Context) throws -> R,
        execution: Session.Control,
    ) throws -> R {
        try pThread.withAttached(execution: execution) { attachment in
            let context = Context(storage: attachment.storage)
            return try body(context)
        }
    }

    borrowing func releasePendingReferences() {
        pThread.withAttached { _ in pThread.storage.releasePendingReferences() }
    }

    borrowing func evaluate(
        _ source: Source,
        filename: String?,
        execution: Session.Control,
    ) throws -> Output {
        switch source {
        case let .interactive(source):
            try execute(
                "evaluate",
                source: source,
                filename: filename,
                execution: execution,
            )
        case let .script(source, arguments):
            try execute(
                "run_script",
                source: ScriptRequest(source: source, arguments: arguments),
                filename: filename,
                execution: execution,
            )
        }
    }

    @_lifetime(borrow owner)
    static func executionModule<Owner: ~Copyable & ~Escapable>(
        in owner: borrowing Owner,
    ) throws -> Object {
        try Object.import(module: "_swift_python_runtime.execution", in: owner)
    }

    private borrowing func execute<Request: Encodable>(
        _ function: String,
        source: Request,
        filename: String?,
        execution: Session.Control,
    ) throws -> Output {
        try pThread.withAttached(execution: execution) { attachment in
            let module = try Self.executionModule(in: attachment)
            let evaluate = try module.attribute(function)
            let result = try evaluate.evaluate(
                source,
                filename: filename,
                execution: execution,
                in: attachment,
            )

            let reply = try result.decode(as: Reply.self)
            if !reply.traceback.isEmpty {
                throw ExecutionError(traceback: reply.traceback, output: reply.output)
            }

            return reply.output
        }
    }
}

private extension Interpreter {
    static func installPackages(
        _ packages: [Runtime.PackageSource.Resolved],
        in attachment: borrowing PThread.Attachment,
    ) throws -> [String] {
        let reader = try Object.makeFunction(Runtime.PackageSource.Reader(packages), in: attachment)
        let sources = try Object(encoding: packages, in: attachment)

        let module = try Object.import(module: "_swift_python_runtime.packages", in: attachment)
        let install = try module.attribute("install")
        let installed = try install.call(
            sources,
            reader,
            Object(encoding: Value.none, in: attachment),
        )
        return try installed.decode(as: [String].self)
    }

    static func configureExecution(
        importPaths: [String],
        in attachment: borrowing PThread.Attachment,
    ) throws {
        let module = try executionModule(in: attachment)
        let configure = try module.attribute("configure")
        _ = try configure.call(Object(encoding: importPaths, in: attachment))
    }

    static func cacheArrayType(in attachment: borrowing PThread.Attachment) throws {
        let module = try Object.import(module: "array", in: attachment)
        let type = try module.attribute("array")
        let storage = attachment.storage
        storage.arrayType = unsafe try storage.references.retain(type.pointer)
    }

    static func installExports(
        _ modules: [Module],
        in attachment: borrowing PThread.Attachment,
    ) throws {
        guard !modules.isEmpty else {
            return
        }

        let storage = attachment.storage
        let registry = ClassRegistry(modules: modules)
        storage.classRegistry = registry

        let exports = try Object.import(module: "_swift_python_runtime.exports", in: attachment)
        let marker = try exports.attribute("_DEFAULT")
        storage.defaultArgumentMarker = unsafe UInt(bitPattern: marker.pointer)

        let install = try exports.attribute("install")
        let plan = Module.Plan(modules)
        let invoke = try Object.makeFunction(ExportDispatcher(plan.functions), in: attachment)
        let metadata = try Object(encoding: plan.metadata, in: attachment)

        _ = try install.call(metadata, invoke)
        registry.finishInstallation()
    }
}

// MARK: Interpreter.Source

extension Interpreter {
    enum Source: Sendable {
        case interactive(String)
        case script(String, arguments: [String])
    }
}

// MARK: Interpreter.StartupRequest

private extension Interpreter {
    struct StartupRequest: Encodable {
        let value: Session.Startup

        func encode(to encoder: inout Encoder) throws {
            switch value {
            case let .source(source):
                try encoder.encode(source, forKey: "source")
            case let .module(module), let .project(_, module):
                try encoder.encode(module, forKey: "module")
            }
        }
    }
}

// MARK: Interpreter.ScriptRequest

private extension Interpreter {
    struct ScriptRequest: Encodable {
        let source: String
        let arguments: [String]

        func encode(to encoder: inout Encoder) throws {
            try encoder.encode(source, forKey: "source")
            try encoder.encode(arguments, forKey: "arguments")
        }
    }
}

// MARK: Interpreter.Reply

private extension Interpreter {
    struct Reply: Decodable {
        let output: Output
        let traceback: String

        init(from decoder: borrowing Decoder) throws {
            output = Output(
                stdout: try decoder.decode(String.self, at: 0),
                stderr: try decoder.decode(String.self, at: 1),
            )
            traceback = try decoder.decode(String.self, at: 2)
        }
    }
}

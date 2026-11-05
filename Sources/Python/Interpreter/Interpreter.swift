//
//  Created by Anton Spivak
//

// MARK: - Interpreter

// A session's interpreter and the code that runs while its thread state is attached.
struct Interpreter: ~Copyable {
    private let state: ThreadState

    private let exportDispatcher: ExportDispatcher
    private let packagePaths: [String]

    init(
        importPaths: [String],
        modules: [Module],
        packages: [PackageSource] = [],
        scheduleRelease: @escaping @Sendable () -> Void = {},
        sessionOrigin: ObjectIdentifier? = nil,
    ) throws {
        let state = try ThreadState(scheduleRelease: scheduleRelease)
        let storage = state.storage

        let exportDispatcher = ExportDispatcher(modules)
        storage.sessionOrigin = sessionOrigin

        let packagePaths = try state.withAttached { attachment in
            try Object.installImporter(in: attachment)
            let packagePaths = try Self.installPackages(packages, in: attachment)
            try Self.configureExecution(importPaths: importPaths + packagePaths, in: attachment)

            let arrayModule = try Object.import(module: "array", in: attachment)
            let arrayType = try arrayModule.attribute("array")
            storage.arrayType = unsafe try storage.references.retain(arrayType.pointer)

            try Self.installExports(
                modules,
                dispatcher: exportDispatcher,
                storage: storage,
                in: attachment,
            )
            return packagePaths
        }

        self.state = consume state
        self.exportDispatcher = exportDispatcher
        self.packagePaths = packagePaths
    }

    borrowing func updateImports(
        paths: [String],
        invalidatingModules modules: [String],
        execution: ExecutionControl? = nil,
    ) throws {
        try state.withAttached { attachment in
            let module = try Object.import(module: "_swift_python_runtime.imports", in: attachment)
            let update = try module.attribute("update_imports")
            let change = [paths + packagePaths, modules]
            if let execution {
                _ = try update.evaluate(change, execution: execution, in: attachment)
            } else {
                _ = try update.call(Object(encoding: change, in: attachment))
            }
        }
    }

    borrowing func restoreImports(paths: [String], discarding: [String]) throws {
        try state.withAttached { attachment in
            let module = try Object.import(module: "_swift_python_runtime.imports", in: attachment)
            let restore = try module.attribute("restore_imports")
            _ = try restore.call(Object(
                encoding: [paths + packagePaths, discarding],
                in: attachment,
            ))
        }
    }

    borrowing func loadedModules(
        files: [String],
        roots: [String],
        execution: ExecutionControl,
    ) throws -> [String] {
        try state.withAttached { attachment in
            let module = try Object.import(module: "_swift_python_runtime.imports", in: attachment)
            let inspect = try module.attribute("loaded_modules")
            let result = try inspect.evaluate(
                ["files": files, "roots": roots],
                execution: execution,
                in: attachment,
            )

            return try result.decode(as: [String].self)
        }
    }

    borrowing func initialize(
        _ startup: Session.Startup,
        execution: ExecutionControl,
    ) throws -> Output {
        try execute(
            "initialize",
            source: StartupRequest(value: startup),
            filename: nil,
            execution: execution,
        )
    }

    borrowing func withContext<R: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Context) throws -> R,
        execution: ExecutionControl,
    ) throws -> R {
        try state.withAttached { attachment in
            state.storage.execution = execution
            defer {
                state.storage.execution = nil
            }
            let context = try Context(in: attachment, execution: execution)
            return try body(context)
        }
    }

    borrowing func releasePendingReferences() {
        state.withAttached { _ in state.storage.releasePendingReferences() }
    }

    borrowing func evaluate(
        _ source: Source,
        filename: String?,
        execution: ExecutionControl,
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

    private borrowing func execute<Request: Encodable>(
        _ function: String,
        source: Request,
        filename: String?,
        execution: ExecutionControl,
    ) throws -> Output {
        try state.withAttached { attachment in
            let module = try Object.import(
                module: "_swift_python_runtime.execution",
                in: attachment,
            )
            state.storage.execution = execution
            let boundary = exportDispatcher.callBoundary
            // A trace interrupt can arrive before Python enters its finally.
            // Cancel this evaluation's remaining Swift work before detaching.
            defer {
                exportDispatcher.cancelPending(since: boundary)
                state.storage.execution = nil
            }
            let evaluate = try module.attribute(function)
            let result = try evaluate.evaluate(
                source,
                filename: filename,
                execution: execution,
                in: attachment,
            )

            let reply = try result.decode(as: ExecutionReply.self)
            if !reply.traceback.isEmpty {
                throw ExecutionError.exception(traceback: reply.traceback, output: reply.output)
            }

            return reply.output
        }
    }
}

private extension Interpreter {
    static func installPackages(
        _ packages: [PackageSource],
        in attachment: borrowing ThreadState.Attachment,
    ) throws -> [String] {
        let reader = try Object.makeFunction(PackageSource.Reader(packages), in: attachment)
        let sources = try Object(
            encoding: packages.map { PackageMetadata(value: $0) },
            in: attachment,
        )
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
        in attachment: borrowing ThreadState.Attachment,
    ) throws {
        let module = try Object.import(module: "_swift_python_runtime.execution", in: attachment)
        let configure = try module.attribute("configure")
        _ = try configure.call(Object(encoding: importPaths, in: attachment))
    }

    static func installExports(
        _ modules: [Module],
        dispatcher: ExportDispatcher,
        storage: InterpreterStorage,
        in attachment: borrowing ThreadState.Attachment,
    ) throws {
        guard !modules.isEmpty else {
            return
        }
        let registry = ClassRegistry(modules: modules)
        storage.classRegistry = registry
        let exports = try Object.import(module: "_swift_python_runtime.exports", in: attachment)
        let marker = try exports.attribute("_DEFAULT")
        storage.defaultArgumentMarker = unsafe UInt(bitPattern: marker.pointer)

        let install = try exports.attribute("install")
        let invoke = try Object.makeFunction(dispatcher, in: attachment)
        let metadata = try Object(
            encoding: modules.map { ModuleMetadata(value: $0) },
            in: attachment,
        )
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

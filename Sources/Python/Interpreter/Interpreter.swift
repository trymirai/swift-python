//
//  Created by Anton Spivak
//

internal import libcpython

// MARK: - Interpreter

// A session's interpreter and the operations that require its attached thread state.
struct Interpreter: ~Copyable {
    let pThread: PThread
    private let packagePaths: [String]

    var references: Reference.Store {
        pThread.storage.references
    }

    init(
        execution: Session.Control,
        importPaths: [String],
        modules: [Module],
        packages: [Runtime.PackageSource.Resolved],
        transactional: Bool,
        scheduleRelease: @escaping @Sendable () -> Void,
        session: Session,
        delegate: (any Session.Delegate)?,
    ) throws {
        let pThread = try PThread(
            transactional: transactional,
            fileAccess: try FileAccess(
                importPaths: importPaths,
                packages: packages,
                delegate: delegate,
            ),
            scheduleRelease: scheduleRelease,
        )
        let storage = pThread.storage

        storage.session = session

        let packagePaths = try pThread.withAttached(execution: execution) { attachment in
            try Self.prepareImports(in: attachment)
            let packagePaths = try Self.installPackages(packages, in: attachment)

            try Self.configureExecution(
                importPaths: Self.searchPaths(importPaths, packages: packagePaths),
                packagePaths: packagePaths,
                in: attachment,
                execution: execution,
            )

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
            let searchPaths = Self.searchPaths(paths, packages: packagePaths)
            _ = try update.call(Object(encoding: [searchPaths, modules], in: attachment))
        }
        pThread.storage.fileAccess?.replaceImportPaths(paths)
    }

    borrowing func withContext<R: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Context) throws -> R,
        execution: Session.Control,
    ) throws -> R {
        try pThread.withAttached(execution: execution) { attachment in
            let context = Context(storage: attachment.storage)
            return try CurrentContext.withAttached { try body(context) }
        }
    }

    borrowing func releasePendingReferences() {
        pThread.withAttached { _ in pThread.storage.releasePendingReferences() }
    }
}

private extension Interpreter {
    static func searchPaths(_ imports: [String], packages: [String]) -> [String] {
        let packagePaths = Set(packages)
        var paths = imports.filter { !packagePaths.contains($0) }
        paths.append(contentsOf: packages)
        return paths
    }

    static func prepareImports(in attachment: borrowing PThread.Attachment) throws {
        let posix = try Object.import(module: "posix", in: attachment)
        try Object.check(
            unsafe CPython_RestrictPOSIXModule(posix.pointer),
            "Unable to restrict the POSIX module.",
        )
        try Object.installImporter(in: attachment)
    }

    static func installPackages(
        _ packages: [Runtime.PackageSource.Resolved],
        in attachment: borrowing PThread.Attachment,
    ) throws -> [String] {
        let reader = try Object.makeFunction(Runtime.PackageSource.Reader(packages), in: attachment)
        let sources = try Object(encoding: packages, in: attachment)

        let module = try Object.import(module: "_swift_python_runtime.packages", in: attachment)
        let install = try module.attribute("install")
        let installed = try install.call(sources, reader)
        return try installed.decode(as: [String].self)
    }

    static func configureExecution(
        importPaths: [String],
        packagePaths: [String],
        in attachment: borrowing PThread.Attachment,
        execution: Session.Control,
    ) throws {
        let module = try executionModule(in: attachment)
        let configure = try module.attribute("configure")
        let imports = try Object(encoding: importPaths, in: attachment)
        let packages = try Object(encoding: packagePaths, in: attachment)
        _ = unsafe try configure.callInterruptibly(
            [imports.pointer, packages.pointer],
            using: execution,
        )
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

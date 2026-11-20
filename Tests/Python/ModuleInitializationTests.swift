//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

// MARK: - ModuleNamespace

@PythonExportedModule("module_namespace")
private enum ModuleNamespace {
    @PythonFunction
    static func increment(_ context: Python::Context) throws -> Int {
        let counter = try context.get("counter", as: Int.self)
        try context.set(counter + 1, forKey: "counter")
        return counter
    }
}

@Test(arguments: [false, true], [false, true])
func moduleInitializationAwaitsSourceAndKeepsGlobals(project: Bool, nested: Bool) async throws {
    try await withTemporaryDirectory { root in
        let package = root.appending("workload")
        try await FileSystem.shared.createDirectory(at: package, withIntermediateDirectories: false)
        try await "OFFSET = 2\n".write(toFileAt: package.appending("helper.py"))

        let name = nested ? "workload.entry" : "workload"
        let source = package.appending(nested ? "entry.py" : "__init__.py")
        if nested {
            try await "LABEL = 'parent'\n".write(toFileAt: package.appending("__init__.py"))
        }
        try await """
        import asyncio, module_namespace
        from .helper import OFFSET

        await asyncio.sleep(0)
        counter = 39
        assert module_namespace.increment() == 39

        def answer():
            return counter + OFFSET

        print("ready")
        """.write(toFileAt: source)

        let runtime = try await Python::Runtime(cacheDirectory: root.appending("cache").string)
        let startup: Python::Session.Startup = if project {
            .project(directory: root.string, module: name)
        } else {
            .module(name)
        }
        let session = try await runtime.session(
            startup,
            importPaths: [root.string],
            modules: [ModuleNamespace.self],
        )
        try await withSession(session) { session in
            #expect(try await session.get("counter", as: Int.self) == 40)
            #expect(await session.startupOutput?.stdout == "ready\n")

            let checked = try await session.evaluate("""
            import importlib, inspect

            assert __name__ == "\(name)"
            assert __package__ == "workload"
            assert __file__ == __spec__.origin
            assert __loader__ is __spec__.loader
            assert importlib.import_module(__name__).answer is answer
            assert "return counter + OFFSET" in inspect.getsource(answer)
            counter = 41
            answer()
            """)
            #expect(checked.output.stdout == "43\n")

            try await session.initialize()
            #expect(try await session.get("counter", as: Int.self) == 41)

            try await session.reset()
            #expect(try await session.get("counter", as: Int.self) == 40)
            #expect(await session.startupOutput?.stdout == "ready\n")
        }
    }
}

@Test(arguments: [false, true])
func moduleInitializationReportsFailuresAndCanRetry(dependency: Bool) async throws {
    try await withTemporaryDirectory { root in
        let source = root.appending("workload.py")
        if dependency {
            let dependencySource = root.appending("ordinary_dependency.py")
            try await asyncModulePrelude.write(toFileAt: dependencySource)
            try await "import ordinary_dependency\n".write(toFileAt: source)
        } else {
            let failingModule = asyncModulePrelude + "raise ValueError('initialization failed')\n"
            try await failingModule.write(toFileAt: source)
        }

        let runtime = try await Python::Runtime()
        let session = try await runtime.session(.module("workload"), importPaths: [root.string])
        try await withSession(session) { session in
            let error = try await #require(throws: Python::Failure.self) {
                try await session.initialize()
            }
            let diagnostic = if dependency {
                "SyntaxError: 'await' outside function"
            } else {
                "ValueError: initialization failed"
            }
            #expect(error.traceback?.contains(diagnostic) == true)

            try await replaceWithReadyModule(at: source)
            #expect(try await session.get("value", as: Int.self) == 42)
            let check = try await session.evaluate("""
            import workload
            assert workload.__dict__ is globals()
            """)
            #expect(check.end == .finished)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func moduleInitializationHonorsCancellation() async throws {
    try await withTemporaryDirectory { root in
        let source = root.appending("workload.py")
        try await "from host import wait\nawait wait()\nvalue = 1\n".write(toFileAt: source)

        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let suspended = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            entered.continuation.finish()
            suspended.continuation.finish()
        }

        let host = Python::Module(
            "host",
            functions: [
                .init("wait") { _ in
                    entered.continuation.yield(())
                    for await _ in suspended.stream {}
                    try Task.checkCancellation()
                    return .none
                },
            ],
        )
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(
            .module("workload"),
            importPaths: [root.string],
            moduleDefinitions: [host],
        )
        try await withSession(session) { session in
            let result = try await runUntilInterrupted(whenReady: entered) {
                try await session.evaluate("value")
            }
            #expect(result.end == .stopped)

            try await replaceWithReadyModule(at: source)
            #expect(try await session.evaluate("value").output.stdout == "42\n")
        }
    }
}

private let asyncModulePrelude: String = "import asyncio\nawait asyncio.sleep(0)\n"

private func replaceWithReadyModule(at path: FilePath) async throws {
    let module = asyncModulePrelude + "value = 42\n"
    try await module.write(toFileAt: path, options: .newFile(replaceExisting: true))
}

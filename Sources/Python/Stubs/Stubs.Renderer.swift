//
//  Created by Anton Spivak
//

// MARK: - Stubs.Renderer

extension Stubs {
    // AST parsing needs CPython, but never installs the selected modules or runs their source.
    // The temporary interpreter is created and destroyed on its own executor thread.
    actor Renderer {
        private nonisolated let executor: Interpreter.Executor

        nonisolated var unownedExecutor: UnownedSerialExecutor {
            unsafe executor.asUnownedSerialExecutor()
        }

        init() throws {
            executor = try Interpreter.Executor()
        }

        isolated deinit {
            executor.finish()
        }

        func render(_ modules: [Module]) throws -> [String: String] {
            try Task.checkCancellation()
            let interpreter = try PThread()
            interpreter.storage.classRegistry = Interpreter.ClassRegistry(modules: modules)
            return try interpreter.withAttached { attachment in
                try Object.installImporter(in: attachment)
                let module = try Object.import(
                    module: "_swift_python_runtime.stubs",
                    in: attachment,
                )
                let generate = try module.attribute("generate")
                let metadata = try Object(encoding: Module.Plan(modules).metadata, in: attachment)
                return try generate.call(metadata).decode(as: [String: String].self)
            }
        }
    }
}

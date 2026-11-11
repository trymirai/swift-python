//
//  Created by Anton Spivak
//

internal import libcpython

extension Interpreter {
    borrowing func initialize(
        _ startup: Session.Startup,
        importPaths: [Runtime.Path],
        redirecting redirects: [Session.Stream: Runtime.Path],
        execution: Session.Control,
    ) throws -> Output {
        let output = try execute(
            "initialize",
            source: StartupRequest(startup: startup, importPaths: importPaths),
            filename: nil,
            redirecting: redirects,
            execution: execution,
        )

        let storage = pThread.storage
        try pThread.withAttached(execution: execution) { attachment in
            let namespace = try Context.currentNamespace(in: attachment)
            storage.namespace = unsafe try storage.references.retain(namespace.pointer)
        }
        return output
    }

    borrowing func evaluate(
        _ source: Source,
        filename: String?,
        redirecting redirects: [Session.Stream: Runtime.Path],
        execution: Session.Control,
    ) throws -> Output {
        func runRequest<Request: Encodable>(
            _ function: String,
            _ request: Request,
        ) throws -> Output {
            try execute(
                function,
                source: request,
                filename: filename,
                redirecting: redirects,
                streamsOutput: execution.hasOutputHandler,
                execution: execution,
            )
        }

        switch source {
        case let .interactive(source):
            return try runRequest("evaluate", source)
        case let .script(source, arguments):
            return try runRequest("run_script", ScriptRequest(source: source, arguments: arguments))
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
        redirecting redirects: [Session.Stream: Runtime.Path],
        streamsOutput: Bool = false,
        execution: Session.Control,
    ) throws -> Output {
        try pThread.withAttached(execution: execution) { attachment in
            let module = try Self.executionModule(in: attachment)
            let function = try module.attribute(function)

            let source = try Object(encoding: source, in: attachment)
            let filename = try Object(encoding: filename, in: attachment)
            let control = try Object.makeFunction(
                Session.Control.Callback(execution: execution, streamsOutput: streamsOutput),
                in: attachment,
            )

            return try Self.withRedirectedStreams(redirects, in: attachment) { streams in
                let result = unsafe try function.callInterruptibly(
                    [source.pointer, filename.pointer, control.pointer, streams.pointer],
                    using: execution,
                )

                return try result.decode(as: Reply.self).outputOrThrow()
            }
        }
    }

    private static func withRedirectedStreams<Result>(
        _ redirects: [Session.Stream: Runtime.Path],
        in attachment: borrowing PThread.Attachment,
        _ body: (borrowing Object) throws -> Result,
    ) throws -> Result {
        let descriptors = try Session.Stream.Descriptors.open(redirects)
        let scope = PThread.Scope.current!
        let previousStreams = scope.streams
        scope.streams = descriptors
        let streams = try Object(encoding: descriptors.numbers, in: attachment)
        Session.Stream.Descriptors.bind(descriptors)
        defer {
            scope.streams = previousStreams
            // Clear the native borrowing slots before the descriptor owner closes them.
            Session.Stream.Descriptors.bind(nil)
            withExtendedLifetime(descriptors) {}
        }

        return try body(streams)
    }
}

// MARK: - Interpreter.Source

extension Interpreter {
    enum Source: Sendable {
        case interactive(String)
        case script(String, arguments: [String])
    }
}

// MARK: - Interpreter.StartupRequest

private extension Interpreter {
    struct StartupRequest: Encodable {
        let startup: Session.Startup
        let importPaths: [Runtime.Path]

        func encode(to encoder: inout Encoder) throws {
            switch startup {
            case let .source(source):
                try encoder.encode(source, forKey: "source")
            case let .module(module):
                try encoder.encode(module, forKey: "module")
            case let .project(directory, module):
                try encoder.encode(directory, forKey: "project")
                try encoder.encode(module, forKey: "module")
                try encoder.encode(importPaths.map(\.string), forKey: "import_paths")
            }
        }
    }
}

// MARK: - Interpreter.ScriptRequest

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

// MARK: - Interpreter.Reply

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

        func outputOrThrow() throws -> Output {
            guard traceback.isEmpty else {
                throw ExecutionError(traceback: traceback, output: output)
            }
            return output
        }
    }
}

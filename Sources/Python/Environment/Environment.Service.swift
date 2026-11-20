//
//  Created by Anton Spivak
//

import Synchronization

// MARK: - Environment.Service

extension Environment {
    // The runtime shares this trusted installer interpreter across its sessions.
    actor Service {
        private static let moduleName = "_swift_python_runtime.packaging"

        private nonisolated let executor: Interpreter.Executor
        private nonisolated let preparations: Session.Operations = .init()

        private var pThread: PThread?
        private var configuration: Configuration?

        nonisolated var unownedExecutor: UnownedSerialExecutor {
            unsafe executor.asUnownedSerialExecutor()
        }

        init() throws {
            executor = try Interpreter.Executor()
        }

        isolated deinit {
            pThread = nil
            executor.finish()
        }

        func open(
            packages: [Runtime.PackageSource.Resolved],
            options: Options,
        ) throws -> Environment.Configuration {
            if let configuration {
                return configuration
            }

            let pThread = try PThread()
            let configuration = try pThread.withAttached { attachment in
                try Self.configure(packages, options: options, in: attachment)
            }

            self.pThread = consume pThread
            self.configuration = configuration
            return configuration
        }

        private static func configure(
            _ packages: [Runtime.PackageSource.Resolved],
            options: Options,
            in attachment: borrowing PThread.Attachment,
        ) throws -> Configuration {
            try Object.installImporter(in: attachment)
            let resolved = try options.resolved(in: attachment)

            let module = try Object.import(module: moduleName, in: attachment)
            let configure = try module(methodNamed: "configure")
            let options = try Object(encoding: resolved, in: attachment)

            return try withEncodedSources(packages, in: attachment) { sources, reader in
                try configure(options, sources, reader).decode(as: Configuration.self)
            }
        }

        func configuration(
            for packages: [Runtime.PackageSource.Resolved],
        ) throws -> Environment.Configuration {
            try withModule { module, attachment in
                let describe = try module(methodNamed: "describe_sources")
                return try Self.withEncodedSources(packages, in: attachment) { sources, reader in
                    try describe(sources, reader).decode(as: Environment.Configuration.self)
                }
            }
        }

        private static func withEncodedSources(
            _ packages: [Runtime.PackageSource.Resolved],
            in attachment: borrowing PThread.Attachment,
            _ body: (borrowing Object, borrowing Object) throws -> Environment.Configuration,
        ) throws -> Environment.Configuration {
            let sources = try Object(encoding: packages, in: attachment)
            let reader = try Object.makeFunction(
                Runtime.PackageSource.Reader(packages),
                in: attachment,
            )
            return try body(sources, reader)
        }

        func projectPackageSource(
            at project: Runtime.Path,
        ) throws -> Runtime.PackageSource.Resolved? {
            let path = try withModule { module, _ in
                try module(methodNamed: "project_package_source")(project.string)
                    .decode(as: String?.self)
            }
            return try path.map { .directory(try Runtime.Path($0)) }
        }

        nonisolated func projectRequirements(
            at project: Runtime.Path,
            target: [String: String] = [:],
            execution: Session.Control,
        ) async throws -> [String] {
            let inputs = try await Request.readingProject(at: project, target: target)
            return try await request(inputs, execution: execution)
        }

        // A shared preparation holds its reservation from manifest read through publication.
        nonisolated func withSharedPreparation<Result>(
            _ prepare: (Session.Control) async throws -> Result,
        ) async throws -> Result {
            try await preparations.withReservation(.queued) {
                try await Environment.withPackageOperation(prepare)
            }
        }

        // The caller keeps interruption active until the operation is ready to publish.
        func request<Reply: Decodable & Sendable>(
            _ request: Request<Reply>,
            execution: Session.Control,
        ) throws -> Reply {
            try execution.checkInterruption()

            return try withModule { module, attachment in
                let function = try module(methodNamed: request.function)
                let argument = try Object(encoding: request, in: attachment)

                let result = unsafe try function.callInterruptibly(
                    [argument.pointer],
                    using: execution,
                )
                return try result.decode(as: Reply.self)
            }
        }

        func encodeManifest(_ manifest: some Encodable & Sendable) throws -> String {
            try withModule { module, attachment in
                let encode = try module(methodNamed: "encode_manifest")
                return try encode(Object(encoding: manifest, in: attachment)).string()
            }
        }

        func decodeManifest<Result: Decodable & Sendable>(
            _ bytes: [UInt8],
            as type: Result.Type,
        ) throws -> Result {
            try withModule { module, attachment in
                let decode = try module(methodNamed: "decode_manifest")
                let data = try Object(bytes: bytes.span, in: attachment)
                return try decode(data).decode(as: type)
            }
        }

        private func withModule<Result: Sendable>(
            _ body: (borrowing Object, borrowing PThread.Attachment) throws -> Result,
        ) throws -> Result {
            switch pThread {
            case let .some(pThread):
                return try pThread.withAttached { attachment in
                    let module = try Object.import(module: Self.moduleName, in: attachment)
                    return try body(module, attachment)
                }
            case .none:
                throw Failure.closed
            }
        }
    }
}

// MARK: - Environment.Service.Lazy

extension Environment.Service {
    final class Lazy: Sendable {
        let packages: [Runtime.PackageSource.Resolved]
        private let options: Options

        private let instance: Mutex<Environment.Service?> = .init(nil)

        init(packages: [Runtime.PackageSource.Resolved], options: Options) {
            self.packages = packages
            self.options = options
        }

        func open() async throws -> (Environment.Service, Environment.Configuration) {
            try Task.checkCancellation()
            let service = try instance.withLock { instance in
                if let instance {
                    return instance
                }
                let service = try Environment.Service()
                instance = service
                return service
            }

            let configuration = try await service.open(packages: packages, options: options)
            return (service, configuration)
        }
    }
}

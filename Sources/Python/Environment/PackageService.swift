//
//  Created by Anton Spivak
//

// A private installer interpreter, without a REPL namespace or Swift exports.
actor PackageService {
    private nonisolated let executor: InterpreterExecutor
    private var state: ThreadState?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        unsafe executor.asUnownedSerialExecutor()
    }

    init() throws {
        executor = try InterpreterExecutor()
    }

    isolated deinit {
        state = nil
        executor.finish()
    }

    func open(
        packages: [PackageSource],
        configuration: ServiceConfiguration,
    ) throws -> PackageConfiguration {
        let state = try ThreadState()
        let result = try state.withAttached { attachment in
            try Object.installImporter(in: attachment)
            let module = try Object.import(
                module: "_swift_python_runtime.packaging",
                in: attachment,
            )
            let configure = try module.attribute("configure")
            let result = try configure.call(
                Object(encoding: configuration, in: attachment),
                Object(encoding: packages.map { PackageMetadata(value: $0) }, in: attachment),
                Object.makeFunction(PackageSource.Reader(packages), in: attachment),
            )
            return try result.decode(as: PackageConfiguration.self)
        }
        self.state = consume state
        return result
    }

    // The caller owns interruption and publication, including completion of its ExecutionControl.
    func request<Reply: Decodable & Sendable>(
        _ request: PackageRequest,
        as type: Reply.Type,
        execution: ExecutionControl,
    ) throws -> Reply {
        try execution.checkInterruption()
        switch state {
        case let .some(state):
            return try state.withAttached { attachment in
                let module = try Object.import(
                    module: "_swift_python_runtime.packaging",
                    in: attachment,
                )
                let function = try module.attribute(request.function)
                let result = try function.evaluate(
                    request,
                    execution: execution,
                    in: attachment,
                )
                return try result.decode(as: type)
            }
        case .none:
            throw SessionError.closed
        }
    }
}

//
//  Created by Anton Spivak
//

// MARK: - Runtime

/// A handle to the process-wide embedded Python runtime.
public struct Runtime: Sendable {
    let packaging: Environment.Service.Lazy
    let options: Options

    private static let startup: Task<Void, any Swift::Error> = .detached {
        let session = Session(
            executor: try Interpreter.Executor(),
            directory: nil,
            importPaths: [],
            modules: [],
        )
        try await session.initializeRuntime()
    }

    /// Creates a runtime with immutable application packages and a shared wheel cache.
    public init(
        packages: [PackageSource] = [],
        cacheDirectory: String? = nil,
        packageIndex: String = "https://pypi.org/simple/",
        options: Options = [],
    ) async throws {
        #if !(os(macOS) || os(Linux) || targetEnvironment(macCatalyst))
        if options.contains(.subprocesses) {
            throw Failure("Python subprocesses are unavailable on this platform.")
        }
        #endif
        try await Self.initialize()

        let packages = try packages.map { try $0.resolved() }
        let cache = try cacheDirectory.map(Path.init)
        let packaging = Environment.Service.Lazy(
            packages: packages,
            options: .init(
                cacheDirectory: cache,
                packageIndex: packageIndex,
            ),
        )
        if !packages.isEmpty || packageIndex != "https://pypi.org/simple/" {
            _ = try await packaging.open()
        }

        self.packaging = packaging
        self.options = options
    }

    /// Creates a runtime using the host's explicit package-cache paths.
    public init(
        packages: [PackageSource] = [],
        paths: Paths,
        packageIndex: String = "https://pypi.org/simple/",
        options: Options = [],
    ) async throws {
        try await self.init(
            packages: packages,
            cacheDirectory: paths.cacheDirectory.string,
            packageIndex: packageIndex,
            options: options,
        )
    }

    static func initialize() async throws {
        try await startup.value
    }
}

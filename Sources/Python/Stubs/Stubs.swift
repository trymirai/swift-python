//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import SystemPackage

// MARK: - Stubs

/// Generates Python interface files for a selected set of exported modules.
/// Module source is inspected without executing it or calling Swift exports.
public struct Stubs: Sendable {
    private let modules: [any ModuleHost.Type]

    /// Selects modules using the same export catalog as the runtime.
    /// Construction does not start Python or perform filesystem operations.
    public init(_ modules: [any ModuleHost.Type]) {
        self.modules = modules
    }

    /// Replaces an absolute output directory with a tree of UTF-8 `.pyi` files.
    ///
    /// Use a directory dedicated to generated stubs: its entire previous contents
    /// are removed. Generation and validation finish before the directory is removed.
    /// Dynamic Python source expressions whose type is unknown are described as `object`.
    public func write(to directory: String) async throws {
        let destination = try Runtime.Path(directory).file.lexicallyNormalized()
        guard destination.lastComponent != nil else {
            throw Runtime.Failure("The stubs directory cannot be the filesystem root.")
        }

        let definitions = try Module.Catalog.resolve(modules)
        try await Runtime.initialize()
        let sources = try await Renderer().render(definitions)
        try Task.checkCancellation()

        let files = FileSystem.shared
        _ = try await files.removeItem(at: destination)
        try await files.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let path = destination.appending(name)
            try await files.createDirectory(
                at: path.removingLastComponent(),
                withIntermediateDirectories: true,
            )
            try await source.write(toFileAt: path, options: .newFile(replaceExisting: false))
        }
    }
}

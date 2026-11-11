//
//  Created by Anton Spivak
//

public import SystemPackage

// MARK: - Path

/// A reference to a `pathlib.Path` in the current Python session.
/// Use its Swift members inside `Session.enqueue` or a Swift export.
@PythonImportedClass(module: "pathlib", name: "Path")
public struct Path {
    @PythonProperty(isReadOnly: true)
    public var name: String
    @PythonProperty(isReadOnly: true)
    public var stem: String
    @PythonProperty(isReadOnly: true)
    public var suffix: String

    @PythonProperty(isReadOnly: true)
    public var parent: Path
    @PythonProperty(isReadOnly: true)
    public var parts: [String]

    /// Creates a path in the supplied context.
    public init(_ path: String, in context: Context) throws {
        self = try context.construct(Self.self, arguments: [path])
    }

    /// Creates a path from a Unicode Swift system path.
    public init(_ path: FilePath, in context: Context) throws {
        guard let string = String(validating: path) else {
            throw Exception(name: "ValueError", message: "Expected a UTF-8 file path.")
        }

        try self.init(string, in: context)
    }

    @PythonFunction("__fspath__")
    public func string() throws -> String

    /// Converts the Python path to a Swift system path.
    public var filePath: FilePath {
        get throws {
            try FilePath(self)
        }
    }

    @PythonFunction("joinpath")
    public func joinPath(_ segment: String) throws -> Path

    @PythonFunction("relative_to")
    public func relativeTo(_ base: Path) throws -> Path

    @PythonFunction("is_absolute")
    public func isAbsolute() throws -> Bool

    @PythonFunction("with_name")
    public func withName(_ name: String) throws -> Path

    @PythonFunction("with_suffix")
    public func withSuffix(_ suffix: String) throws -> Path

    @PythonFunction
    public func resolve(strict: Bool = false) throws -> Path

    @PythonFunction
    public func exists() throws -> Bool

    @PythonFunction("is_file")
    public func isFile() throws -> Bool

    @PythonFunction("is_dir")
    public func isDirectory() throws -> Bool
}

// MARK: - FilePath

public extension FilePath {
    /// Copies a Python path into a Swift system path.
    init(_ path: Python::Path) throws {
        let value = try path.string()
        guard !value.utf8.contains(0) else {
            throw Exception(name: "ValueError", message: "A file path cannot contain NUL.")
        }
        self.init(value)
    }
}

//
//  Created by Anton Spivak
//

public import SystemPackage

// MARK: - Path

/// A reference to a `pathlib.Path` in the current Python session.
/// Use its Swift members inside `Session.enqueue` or a synchronous Swift export.
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

    /// Creates a path in the attached interpreter.
    public init(_ path: String) throws {
        self = try Self.withClass { try $0.call(path).decode() }
    }

    /// Creates a path from a Unicode Swift system path.
    public init(_ path: FilePath) throws {
        guard let string = String(validating: path) else {
            throw Exception(name: "ValueError", message: "Expected a UTF-8 file path.")
        }

        try self.init(string)
    }

    @PythonFunction("__fspath__")
    public func string() throws -> String

    /// Converts the Python path to a Swift system path.
    public var filePath: FilePath {
        get throws {
            let path = try string()
            guard !path.utf8.contains(0) else {
                throw Exception(name: "ValueError", message: "A file path cannot contain NUL.")
            }

            return FilePath(path)
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

//
//  Created by Anton Spivak
//

internal import _NIOFileSystem
internal import SystemPackage

extension Environment.Service.Request where Reply == [String] {
    static func readingProject(at directory: Runtime.Path) async throws -> Self {
        let path = directory.file
        guard try await FileSystem.shared.info(forFileAt: path)?.type == .directory else {
            throw Exception(
                name: "FileNotFoundError",
                message: "Python project directory does not exist: \(path)",
            )
        }
        return try await .project(
            pyproject: readManifest(at: path.appending("pyproject.toml")),
            requirements: readManifest(at: path.appending("requirements.txt")),
        )
    }

    private static func readManifest(at path: FilePath) async throws -> String? {
        guard try await FileSystem.shared.info(forFileAt: path)?.type == .regular else {
            return nil
        }
        let bytes = try await [UInt8](contentsOf: path, maximumSizeAllowed: .unlimited)
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw Exception(
                name: "UnicodeDecodeError",
                message: "Project requirements must be UTF-8: \(path)",
            )
        }
        return text
    }
}

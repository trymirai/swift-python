//
//  Created by Anton Spivak
//

internal import Foundation

extension PackageRequest {
    static func readingProject(at directory: String?) throws -> PackageRequest {
        guard let directory else {
            return .project(pyproject: nil, requirements: nil)
        }
        var isDirectory: ObjCBool = false
        guard
            unsafe FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw Exception(
                name: "FileNotFoundError",
                message: "Python project directory does not exist: \(directory)",
            )
        }
        return try .project(
            pyproject: readManifest(at: directory + "/pyproject.toml"),
            requirements: readManifest(at: directory + "/requirements.txt"),
        )
    }

    private static func readManifest(at path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        let data = try Data(contentsOf: url)
        guard let text = String(validating: data, as: UTF8.self) else {
            throw Exception(
                name: "UnicodeDecodeError",
                message: "Project requirements must be UTF-8: \(path)",
            )
        }
        return text
    }
}

//
//  Created by Anton Spivak
//

internal import Foundation

extension EnvironmentStore {
    static func includeModule(
        _ name: String,
        project: String,
        destination: String,
        execution: ExecutionControl,
    ) throws {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        let package = project + "/" + name
        if
            unsafe files.fileExists(atPath: package, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            try copyDirectory(package, to: destination + "/" + name, execution: execution)
        } else if files.fileExists(atPath: package + ".py") {
            try copyProjectFile(package + ".py", to: destination + "/" + name + ".py")
        } else {
            throw Exception(name: "ModuleNotFoundError", message: name)
        }
    }

    static func publishArchive(_ source: String, to destination: String) throws {
        if
            FileManager.default.fileExists(atPath: destination),
            FileManager.default.contentsEqual(atPath: source, andPath: destination)
        {
            return
        }
        try replace(source, with: destination)
    }

    private static func copyDirectory(
        _ source: String,
        to destination: String,
        execution: ExecutionControl,
    ) throws {
        let files = FileManager.default
        for name in try files.contentsOfDirectory(atPath: source).sorted()
            where !name.hasPrefix(".") && name != "__pycache__"
        {
            try execution.checkInterruption()
            let original = source + "/" + name
            let target = destination + "/" + name
            var isDirectory: ObjCBool = false
            guard unsafe files.fileExists(atPath: original, isDirectory: &isDirectory) else {
                throw Exception(name: "FileNotFoundError", message: original)
            }
            if isDirectory.boolValue {
                let attributes = try files.attributesOfItem(atPath: original)
                if attributes[.type] as? FileAttributeType != .typeSymbolicLink {
                    try copyDirectory(original, to: target, execution: execution)
                }
            } else if !name.hasSuffix(".pyc") && !name.hasSuffix(".pyo") {
                try copyProjectFile(original, to: target)
            }
        }
    }

    private static func copyProjectFile(_ source: String, to target: String) throws {
        let files = FileManager.default
        if files.fileExists(atPath: target) {
            throw Exception(
                name: "ValueError",
                message: "Project module collides with a dependency: \(target)",
            )
        }
        let destination = URL(fileURLWithPath: target)
        try files.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try files.copyItem(
            atPath: URL(fileURLWithPath: source).resolvingSymlinksInPath().path,
            toPath: target,
        )
    }
}

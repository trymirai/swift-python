//
//  Created by Anton Spivak
//

// MARK: - PackageRequest

enum PackageRequest: Sendable {
    case project(pyproject: String?, requirements: String?)
    case script(source: String)

    case normalize([String])
    case names([String])

    case prepare(
        requirements: [String],
        installed: [String: InstalledPackage],
        fingerprint: String?,
        update: Bool,
    )

    case moduleName(String)
    case archive(directory: String, output: String)

    var function: String {
        switch self {
        case .project:
            "project"
        case .script:
            "script"
        case .normalize:
            "normalize"
        case .names:
            "names"
        case .prepare:
            "prepare"
        case .moduleName:
            "module_name"
        case .archive:
            "archive"
        }
    }
}

// MARK: Encodable

extension PackageRequest: Encodable {
    func encode(to encoder: inout Encoder) throws {
        switch self {
        case let .project(pyproject, requirements):
            try encoder.encode(pyproject, forKey: "pyproject")
            try encoder.encode(requirements, forKey: "requirements")
        case let .script(source):
            try encoder.encode(source, forKey: "source")
        case let .normalize(requirements):
            try encoder.encode(requirements, forKey: "requirements")
        case let .names(names):
            try encoder.encode(names, forKey: "names")
        case let .prepare(requirements, installed, fingerprint, update):
            try encoder.encode(requirements, forKey: "requirements")
            try encoder.encode(installed, forKey: "installed")
            try encoder.encode(fingerprint, forKey: "fingerprint")
            try encoder.encode(update, forKey: "update")
        case let .moduleName(module):
            try encoder.encode(module, forKey: "module")
        case let .archive(directory, output):
            try encoder.encode(directory, forKey: "directory")
            try encoder.encode(output, forKey: "output")
        }
    }
}

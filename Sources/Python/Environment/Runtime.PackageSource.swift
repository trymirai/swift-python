//
//  Created by Anton Spivak
//

// MARK: - Runtime.PackageSource

public extension Runtime {
    /// An immutable source of installed Python packages for a runtime or session.
    enum PackageSource: Sendable {
        /// An existing site-packages directory, including distribution metadata.
        case directory(String)

        /// A ZIP file rooted at the contents of a site-packages directory.
        case archive(String)

        /// Site-packages ZIP bytes, for example from SwiftPM's `embedInCode` resource rule.
        case embedded([UInt8])
    }
}

extension Runtime.PackageSource {
    func resolved() throws -> Resolved {
        switch self {
        case let .directory(path):
            try .directory(Runtime.Path(path))
        case let .archive(path):
            try .archive(Runtime.Path(path))
        case let .embedded(bytes):
            .embedded(bytes)
        }
    }
}

// MARK: - Runtime.PackageSource.Resolved

extension Runtime.PackageSource {
    enum Resolved: Sendable {
        case directory(Runtime.Path)
        case archive(Runtime.Path)
        case embedded([UInt8])

        var source: Runtime.PackageSource {
            switch self {
            case let .directory(path):
                .directory(path.string)
            case let .archive(path):
                .archive(path.string)
            case let .embedded(bytes):
                .embedded(bytes)
            }
        }
    }
}

// MARK: - Runtime.PackageSource.Resolved + Encodable

extension Runtime.PackageSource.Resolved: Encodable {
    func encode(to encoder: inout Encoder) throws {
        switch self {
        case let .directory(path):
            try encoder.encode(path.string, forKey: "directory")
        case let .archive(path):
            try encoder.encode(path.string, forKey: "archive")
        case let .embedded(bytes):
            // The reader serves the archive bytes on demand.
            try encoder.encode(bytes.count, forKey: "size")
        }
    }
}

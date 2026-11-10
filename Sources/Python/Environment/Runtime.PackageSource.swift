//
//  Created by Anton Spivak
//

// MARK: - Runtime.PackageSource

public extension Runtime {
    /// An immutable source of installed Python packages for a runtime or session.
    enum PackageSource: Sendable {
        /// An existing site-packages directory, including distribution metadata.
        case directory(String)

        /// A prepared site-packages ZIP, for example in application resources.
        case archive(String)

        /// A ZIP of an installed site-packages tree, including resources and metadata.
        /// SwiftPM's embedInCode resource rule can supply these bytes.
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
    enum Resolved: Sendable, Encodable {
        case directory(Runtime.Path)
        case archive(Runtime.Path)
        case embedded([UInt8])

        func encode(to encoder: inout Encoder) throws {
            switch self {
            case let .directory(path):
                try encoder.encode(path.string, forKey: "directory")
            case let .archive(path):
                try encoder.encode(path.string, forKey: "archive")
            case let .embedded(bytes):
                try encoder.encode(bytes.count, forKey: "size")
            }
        }
    }
}

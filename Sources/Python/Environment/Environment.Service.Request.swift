//
//  Created by Anton Spivak
//

// MARK: - Environment.Service.Request

extension Environment.Service {
    struct Request<Reply: Decodable & Sendable>: Encodable, Sendable {
        let function: String
        private let encodeFields: @Sendable (inout Encoder) throws -> Void

        fileprivate init(
            _ function: String,
            encode: @escaping @Sendable (inout Encoder) throws -> Void,
        ) {
            self.function = function
            self.encodeFields = encode
        }

        func encode(to encoder: inout Encoder) throws {
            try encodeFields(&encoder)
        }

        private static func encodeResolutionInputs(
            _ requirements: [String],
            base: [String: Environment.BasePackage],
            to encoder: inout Encoder,
        ) throws {
            try encoder.encode(requirements, forKey: "requirements")
            try encoder.encode(base, forKey: "base")
        }
    }
}

extension Environment.Service.Request where Reply == [String] {
    static func project(
        pyproject: String?,
        requirements: String?,
        target: [String: String],
    ) -> Self {
        Self("project") { encoder in
            try encoder.encode(target, forKey: "target")
            try encoder.encode(pyproject, forKey: "pyproject")
            try encoder.encode(requirements, forKey: "requirements")
        }
    }

    static func script(source: String) -> Self {
        Self("script") { try $0.encode(source, forKey: "source") }
    }

    static func names(_ names: [String]) -> Self {
        Self("names") { try $0.encode(names, forKey: "names") }
    }
}

extension Environment.Service.Request where Reply == [Environment.Service.Requirement] {
    static func normalize(_ requirements: [String]) -> Self {
        Self("normalize") { try $0.encode(requirements, forKey: "requirements") }
    }
}

extension Environment.Service.Request where Reply == Environment.Preparation {
    static func prepare(
        requirements: [String],
        base: [String: Environment.BasePackage],
        target: [String: String] = [:],
        local: [String] = [],
        removed: [String] = [],
        installed: [String: Environment.InstalledPackage],
        fingerprint: String?,
        update: Bool,
        replaceFiles: Bool = true,
    ) -> Self {
        Self("prepare") { encoder in
            try encodeResolutionInputs(requirements, base: base, to: &encoder)

            try encoder.encode(target, forKey: "target")
            try encoder.encode(local, forKey: "local")
            try encoder.encode(removed, forKey: "removed")

            try encoder.encode(installed, forKey: "installed")
            try encoder.encode(fingerprint, forKey: "fingerprint")

            try encoder.encode(update, forKey: "update")
            try encoder.encode(replaceFiles, forKey: "replace_files")
        }
    }
}

extension Environment.Service.Request where Reply == String {
    static func resolutionFingerprint(
        requirements: [String],
        base: [String: Environment.BasePackage],
    ) -> Self {
        Self("fingerprint") { encoder in
            try encodeResolutionInputs(requirements, base: base, to: &encoder)
        }
    }

    static func packageFingerprint(_ packages: [String: Environment.InstalledPackage]) -> Self {
        Self("package_fingerprint") { encoder in
            try encoder.encode(packages.mapValues(\.digest), forKey: "digests")
        }
    }

    static func moduleName(_ module: String) -> Self {
        Self("module_name") { try $0.encode(module, forKey: "module") }
    }
}

// MARK: - Environment.Service.None

extension Environment.Service {
    struct None: Decodable, Sendable {
        init(from decoder: borrowing Decoder) throws {
            guard decoder.isNone else {
                throw decoder.mismatch("None")
            }
        }
    }
}

extension Environment.Service.Request where Reply == Environment.Service.None {
    static func archive(directory: String, output: String) -> Self {
        Self("archive") { encoder in
            try encoder.encode(directory, forKey: "directory")
            try encoder.encode(output, forKey: "output")
        }
    }
}

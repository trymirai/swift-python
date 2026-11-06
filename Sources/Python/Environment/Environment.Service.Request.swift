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
    }
}

extension Environment.Service.Request where Reply == [String] {
    static func project(pyproject: String?, requirements: String?) -> Self {
        Self("project") {
            try $0.encode(pyproject, forKey: "pyproject")
            try $0.encode(requirements, forKey: "requirements")
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
        installed: [String: Environment.InstalledPackage],
        fingerprint: String?,
        update: Bool,
        replaceFiles: Bool = true,
    ) -> Self {
        Self("prepare") {
            try $0.encode(requirements, forKey: "requirements")
            try $0.encode(installed, forKey: "installed")
            try $0.encode(fingerprint, forKey: "fingerprint")
            try $0.encode(update, forKey: "update")
            try $0.encode(replaceFiles, forKey: "replace_files")
        }
    }
}

extension Environment.Service.Request where Reply == String {
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
        Self("archive") {
            try $0.encode(directory, forKey: "directory")
            try $0.encode(output, forKey: "output")
        }
    }
}

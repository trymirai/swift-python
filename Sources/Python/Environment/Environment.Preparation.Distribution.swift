//
//  Created by Anton Spivak
//

internal import SystemPackage

// MARK: - Environment.Preparation.Distribution

extension Environment.Preparation {
    struct Distribution: Decodable, Sendable {
        let record: Environment.InstalledPackage
        let directory: Runtime.Path
        let files: [Member]

        init(from decoder: borrowing Decoder) throws {
            record = try decoder.decode(Environment.InstalledPackage.self, forKey: "record")
            directory = try Runtime.Path(decoder.decode(String.self, forKey: "directory"))
            files = try decoder.decode([Member].self, forKey: "files")
        }
    }
}

// MARK: - Environment.Preparation.Distribution.Member

extension Environment.Preparation.Distribution {
    struct Member: Decodable, Sendable {
        let path: FilePath

        init(from decoder: borrowing Decoder) throws {
            let string = try decoder.string()
            guard
                !string.isEmpty, !string.hasPrefix("/"), !string.utf8.contains(0),
                string.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else {
                throw Exception(name: "ValueError", message: "Invalid wheel member: \(string)")
            }
            path = FilePath(string)
        }
    }
}

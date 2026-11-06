//
//  Created by Anton Spivak
//

internal import SystemPackage

extension Runtime {
    struct Path: Sendable {
        let file: FilePath

        var string: String {
            file.string
        }

        init(_ string: String) throws {
            guard !string.utf8.contains(0) else {
                throw Failure("A Python path cannot contain NUL: \(string.debugDescription)")
            }
            try self.init(FilePath(string))
        }

        init(_ file: FilePath) throws {
            guard file.isAbsolute, String(validating: file) != nil else {
                throw Failure("Expected an absolute UTF-8 Python path: \(file)")
            }
            self.file = file
        }
    }
}

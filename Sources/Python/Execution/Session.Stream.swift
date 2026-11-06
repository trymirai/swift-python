//
//  Created by Anton Spivak
//

internal import SystemPackage

// MARK: - Session.Stream

public extension Session {
    /// A standard stream that can be redirected to a file for one execution.
    enum Stream: String, Hashable, Sendable {
        case stdin
        case stdout
        case stderr
    }
}

// MARK: - Session.Stream.Redirects

extension Session.Stream {
    struct Redirects: Encodable, Sendable {
        private let stdin: Runtime.Path?
        private let stdout: Runtime.Path?
        private let stderr: Runtime.Path?

        init(_ paths: [Session.Stream: FilePath]) throws {
            stdin = try paths[.stdin].map(Runtime.Path.init)
            stdout = try paths[.stdout].map(Runtime.Path.init)
            stderr = try paths[.stderr].map(Runtime.Path.init)
        }

        func encode(to encoder: inout Encoder) throws {
            try encoder.encode(stdin?.string, forKey: Session.Stream.stdin.rawValue)
            try encoder.encode(stdout?.string, forKey: Session.Stream.stdout.rawValue)
            try encoder.encode(stderr?.string, forKey: Session.Stream.stderr.rawValue)
        }
    }
}

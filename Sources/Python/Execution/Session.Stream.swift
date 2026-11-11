//
//  Created by Anton Spivak
//

internal import libcpython
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

// MARK: - Session.Stream.Descriptors

extension Session.Stream {
    // Active callbacks retain their streams until every Python access has finished.
    final class Descriptors: Sendable {
        let numbers: [String: Int32]

        private let files: [Session.Stream: FileDescriptor]

        static func open(_ paths: [Session.Stream: Runtime.Path]) throws -> Descriptors {
            try Descriptors(paths)
        }

        private init(_ paths: [Session.Stream: Runtime.Path]) throws {
            var files = [Session.Stream: FileDescriptor]()
            do {
                for stream in [Session.Stream.stdout, .stderr, .stdin] {
                    guard let path = paths[stream]?.file else {
                        continue
                    }

                    files[stream] = try Self.open(stream, at: path)
                }
            } catch {
                Self.close(files)
                throw error
            }

            self.files = files
            self.numbers = Dictionary(uniqueKeysWithValues: files.lazy
                .map { ($0.key.rawValue, $0.value.rawValue) })
        }

        deinit {
            Self.close(files)
        }

        static func bind(_ descriptors: Descriptors?) {
            CPython_SetStreamDescriptors(
                descriptors?.files[.stdin]?.rawValue ?? -1,
                descriptors?.files[.stdout]?.rawValue ?? -1,
                descriptors?.files[.stderr]?.rawValue ?? -1,
            )
        }

        private static func open(
            _ stream: Session.Stream,
            at path: FilePath,
        ) throws -> FileDescriptor {
            if stream == .stdin {
                return try .open(path, .readOnly, options: .closeOnExec)
            }
            return try .open(
                path,
                .writeOnly,
                options: [.append, .create, .closeOnExec],
                permissions: .init(rawValue: 0o666),
            )
        }

        private static func close(_ files: [Session.Stream: FileDescriptor]) {
            for descriptor in files.values {
                try? descriptor.close()
            }
        }
    }
}

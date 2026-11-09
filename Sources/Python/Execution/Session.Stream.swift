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

// MARK: - Session.Stream.Descriptors

extension Session.Stream {
    // Python borrows these descriptors for the duration of one call.
    struct Descriptors: ~Copyable {
        private var files: [Session.Stream: FileDescriptor] = [:]

        static func open(_ paths: [Session.Stream: Runtime.Path]) throws -> Descriptors {
            var descriptors = Descriptors()
            for stream in [Session.Stream.stdout, .stderr, .stdin] {
                guard let path = paths[stream]?.file else {
                    continue
                }
                let descriptor: FileDescriptor = if stream == .stdin {
                    try .open(path, .readOnly, options: .closeOnExec)
                } else {
                    try .open(
                        path,
                        .writeOnly,
                        options: [.append, .create, .closeOnExec],
                        permissions: .init(rawValue: 0o666),
                    )
                }
                descriptors.files[stream] = descriptor
            }
            return descriptors
        }

        var numbers: [String: Int32] {
            Dictionary(uniqueKeysWithValues: files.lazy
                .map { ($0.key.rawValue, $0.value.rawValue) })
        }

        deinit {
            for descriptor in files.values {
                try? descriptor.close()
            }
        }
    }
}

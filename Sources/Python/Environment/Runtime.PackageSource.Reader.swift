//
//  Created by Anton Spivak
//

// MARK: - Runtime.PackageSource.Reader

extension Runtime.PackageSource {
    struct Reader {
        let sources: [Runtime.PackageSource.Resolved]

        init(_ sources: [Runtime.PackageSource.Resolved]) {
            self.sources = sources
        }
    }
}

// MARK: - Runtime.PackageSource.Reader + Object.Callable

extension Runtime.PackageSource.Reader: Object.Callable {
    @_lifetime(borrow attachment)
    func call(
        _ arguments: borrowing Object,
        in attachment: borrowing PThread.Attachment,
    ) throws -> Object {
        guard
            let index = try? arguments.item(at: 0).decode(as: Int.self),
            sources.indices.contains(index),
            case let .embedded(bytes) = sources[index],
            let offset = try? arguments.item(at: 1).decode(as: Int.self),
            let count = try? arguments.item(at: 2).decode(as: Int.self),
            offset >= 0,
            count >= 0,
            offset <= bytes.count,
            count <= bytes.count - offset
        else {
            throw Exception(name: "ValueError", message: "Invalid embedded package read.")
        }

        // Keep the archive shared and copy only the requested range into CPython.
        let range = offset ..< (offset + count)
        return try Object(bytes: bytes.span.extracting(range), in: attachment)
    }
}

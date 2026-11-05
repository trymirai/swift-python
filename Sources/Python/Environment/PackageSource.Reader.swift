//
//  Created by Anton Spivak
//

// MARK: - PackageSource.Reader

extension PackageSource {
    struct Reader {
        let sources: [PackageSource]

        init(_ sources: [PackageSource]) {
            self.sources = sources
        }
    }
}

// MARK: - PackageSource.Reader + Object.Callable

extension PackageSource.Reader: Object.Callable {
    @_lifetime(borrow attachment)
    func call(
        _ arguments: borrowing Object,
        in attachment: borrowing ThreadState.Attachment,
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

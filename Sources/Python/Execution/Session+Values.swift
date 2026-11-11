//
//  Created by Anton Spivak
//

public extension Session {
    nonisolated func get<T: Decodable & Sendable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
        in context: Context? = nil,
    ) async throws -> T {
        try await enqueue(in: context) { context in try context.get(name, as: type) }
    }

    nonisolated func set<T: Encodable & Sendable & ~Copyable>(
        _ value: consuming T,
        forKey name: String,
        in context: Context? = nil,
    ) async throws {
        let transfer = Session.Transfer(consume value)
        try await enqueue(in: context) { context in
            let value = transfer.take()
            try context.set(value, forKey: name)
        }
    }

    nonisolated func remove(_ name: String, in context: Context? = nil) async throws {
        try await enqueue(in: context) { context in try context.remove(name) }
    }
}

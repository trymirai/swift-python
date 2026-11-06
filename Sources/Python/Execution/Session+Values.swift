//
//  Created by Anton Spivak
//

public extension Session {
    nonisolated func get<T: Decodable & Sendable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
    ) async throws -> T {
        try await enqueue { context in try context.get(name, as: type) }
    }

    nonisolated func set<T: Encodable & Sendable & ~Copyable>(
        _ value: consuming T,
        forKey name: String,
    ) async throws {
        let transfer = ValueTransfer(consume value)
        try await enqueue { context in
            let value = transfer.take()
            try context.set(value, forKey: name)
        }
    }

    nonisolated func remove(_ name: String) async throws {
        try await enqueue { context in try context.remove(name) }
    }
}

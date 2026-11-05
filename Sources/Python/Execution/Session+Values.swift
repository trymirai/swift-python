//
//  Created by Anton Spivak
//

public extension Session {
    nonisolated func get<T: Decodable & Sendable & ~Copyable>(
        _ name: String,
        as type: T.Type = T.self,
    ) async throws -> T {
        try await enqueue { context in try context[name].get(as: type) }
    }

    nonisolated func set<T: Encodable & Sendable & ~Copyable>(
        _ name: String,
        to value: consuming T,
    ) async throws {
        let transfer = ValueTransfer(consume value)
        try await enqueue { context in
            let value = transfer.take()
            try context[name].set(value)
        }
    }

    nonisolated func remove(_ name: String) async throws {
        try await enqueue { context in try context[name].remove() }
    }
}

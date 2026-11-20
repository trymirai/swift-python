//
//  Created by Anton Spivak
//

public extension Session {
    /// Calls a reference in one queue turn and awaits the result if it is awaitable.
    nonisolated func call<Result: Decodable & Sendable & ~Copyable>(
        _ function: Reference,
        arguments: [any Encodable & Sendable] = [],
        keywords: [(String, any Encodable & Sendable)] = [],
        as type: Result.Type = Result.self,
        in parent: Context? = nil,
        scope: (any Sendable)? = nil,
    ) async throws -> Result {
        let call = ImportedCall<Session.Transfer<Result>>(
            .instance(function),
            arguments: arguments,
            keywords: keywords,
            as: type,
        )
        return try await call.value(in: self, from: parent, scope: scope).take()
    }
}

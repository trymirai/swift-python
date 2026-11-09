//
//  Created by Anton Spivak
//

// MARK: - Managed

/// Retains an exported instance's Python object and accesses it on its session.
public struct Managed<Instance: _PClass>: Sendable {
    private let session: Session
    private let reference: Reference

    public init(_ instance: borrowing Instance) throws {
        let context = try Context()
        session = try context.requireSession()
        reference = try context.encode(instance).retain(in: context)
    }

    public func callAsFunction<Result: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Instance) throws -> Result,
    ) async throws -> Result {
        try await session.enqueue(in: reference.storage.references) { context in
            let instance = try context.object(reference).decode(as: Instance.self)
            return try body(instance)
        }
    }
}

public extension Managed where Instance: Sendable {
    /// Resolves the instance on its session before running asynchronous Swift code.
    func callAsFunction<Result: Sendable & ~Copyable>(
        _ body: @Sendable (borrowing Instance) async throws -> Result,
    ) async throws -> Result {
        let instance = try await session.enqueue(in: reference.storage.references) { context in
            try context.object(reference).decode(as: Instance.self)
        }
        defer { withExtendedLifetime(reference) {} }
        return try await body(instance)
    }
}

//
//  Created by Anton Spivak
//

public extension Session {
    nonisolated var packages: Packages {
        Packages(session: self)
    }

    struct Packages: Sendable {
        public enum Change: Sendable, Equatable {
            case applied

            /// Reset the interpreter and retry the change.
            case requiresReset
        }

        fileprivate let session: Session

        /// The selected version of each distribution visible to the session.
        public func installed(in context: Context? = nil) async throws -> [String: String] {
            try await session.withExecution(in: context) { session, _ in
                try await session.environment?.installed() ?? [:]
            }
        }

        /// Re-reads project requirements while preserving compatible installed versions.
        public func resolve(in context: Context? = nil) async throws -> Change {
            try await apply(.resolve, in: context)
        }

        /// Selects current compatible versions for the local environment.
        public func update(in context: Context? = nil) async throws -> Change {
            try await apply(.update, in: context)
        }

        public func install(
            requirements: [String],
            in context: Context? = nil,
        ) async throws -> Change {
            guard !requirements.isEmpty else {
                throw Runtime.Failure("Expected package requirements.")
            }
            return try await apply(.install(requirements), in: context)
        }

        public func uninstall(
            _ names: [String],
            in context: Context? = nil,
        ) async throws -> Change {
            guard !names.isEmpty else {
                throw Runtime.Failure("Expected local distribution names.")
            }
            return try await apply(.uninstall(names), in: context)
        }

        private func apply(
            _ change: Environment.Change,
            in context: Context?,
        ) async throws -> Change {
            try await session.withExecution(in: context) { session, execution in
                guard let environment = session.environment else {
                    throw Session.Error.closed
                }
                return try await environment.apply(
                    change,
                    canReplacePackages: session.canReplacePackages,
                    execution: execution,
                )
            }
        }
    }
}

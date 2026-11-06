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

        /// Application and local distributions visible to the session.
        public func installed() async throws -> [String: String] {
            try await session.withExecution { session, _ in
                try await session.environment?.installed() ?? [:]
            }
        }

        /// Re-reads project requirements while preserving compatible installed versions.
        public func resolve() async throws -> Change {
            try await apply(.resolve)
        }

        /// Selects current compatible versions while retaining the fixed application base.
        public func update() async throws -> Change {
            try await apply(.update)
        }

        public func install(requirements: [String]) async throws -> Change {
            guard !requirements.isEmpty else {
                throw Runtime.Failure("Expected package requirements.")
            }
            return try await apply(.install(requirements))
        }

        public func uninstall(_ names: [String]) async throws -> Change {
            guard !names.isEmpty else {
                throw Runtime.Failure("Expected local distribution names.")
            }
            return try await apply(.uninstall(names))
        }

        private func apply(_ change: Environment.Change) async throws -> Change {
            try await session.withExecution { session, execution in
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

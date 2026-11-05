//
//  Created by Anton Spivak
//

public extension Session {
    /// Re-reads project requirements while preserving compatible installed versions.
    nonisolated func resolvePackages() async throws {
        try await changePackages(.resolve)
    }

    /// Selects current compatible versions while retaining the fixed application base.
    nonisolated func updatePackages() async throws {
        try await changePackages(.update)
    }

    nonisolated func install(requirements: [String]) async throws {
        guard !requirements.isEmpty else {
            throw RuntimeFailure("Expected package requirements.")
        }
        try await changePackages(.install(requirements))
    }

    nonisolated func uninstall(packages names: [String]) async throws {
        guard !names.isEmpty else {
            throw RuntimeFailure("Expected local distribution names.")
        }
        try await changePackages(.uninstall(names))
    }
}

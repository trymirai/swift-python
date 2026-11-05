//
//  Created by Anton Spivak
//

struct StandardLibraryBuilder: ~Copyable {
    let workspace: BuildWorkspace
    let jobCount: Int

    func run() async throws {
        let freezer = try await buildFreezer()
        let library = try await collectLibrary()

        workspace.logger.info("Embedding the standard library")

        try await writeFrozenModules(library, using: freezer)
        try await writeResources(library)
        try await writeGetPath()

        workspace.logger.info(
            "Embedded \(library.modules.count) modules and \(library.resources.count) source/resource files",
        )
    }
}

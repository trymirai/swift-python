//
//  Created by Anton Spivak
//

import _NIOFileSystem

struct StandardLibraryBuilder: ~Copyable {
    let workspace: BuildWorkspace
    let jobCount: Int

    func run() async throws {
        try await workspace.fileSystem.createDirectory(
            at: workspace.outputDirectory,
            withIntermediateDirectories: true,
        )
        try await writePatchedSources()

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

    func writeGeneratedSource(
        _ filename: String,
        _ body: sending (inout BufferedWriter<WriteFileHandle>) async throws -> Void,
    ) async throws {
        try await workspace.fileSystem.withFileHandle(
            forWritingAt: workspace.outputDirectory.appending(filename),
            options: .newFile(replaceExisting: true),
        ) { handle in
            try await handle.withBufferedWriter(execute: body)
        }
    }
}

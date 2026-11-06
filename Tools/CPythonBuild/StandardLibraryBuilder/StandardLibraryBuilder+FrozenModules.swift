//
//  Created by Anton Spivak
//

import _NIOFileSystem
import SystemPackage

extension StandardLibraryBuilder {
    func writeFrozenModules(_ library: Library, using freezer: FilePath) async throws {
        let output = workspace.outputDirectory
        try await writeGeneratedSource("Frozen.c") { writer in
            let upstream = try await workspace.read(
                textFrom: workspace.sourceDirectory.appending("Python/frozen.c"),
            )

            let include = "#include \"frozen_modules/"
            let frozenHeaders = Set(upstream.split(separator: "\n").compactMap { line in
                line.hasPrefix(include) ? String(line.dropFirst(include.count).dropLast()) : nil
            })
            let frozenSource = upstream.replacing(
                include,
                with: "#include \"Bootstrap/Python/frozen_modules/",
            )

            try await writer.write(contentsOf: frozenSource.utf8)
            try await writer.write(contentsOf: "\n#include \"embedded_data.h\"\n\n".utf8)

            try await workspace
                .fileSystem
                .withTemporaryDirectory(prefix: output) { _, directory in
                    let header = directory.appending("Module.h")
                    for module in library.modules
                        where !frozenHeaders.contains(module.name + ".h")
                    {
                        let source = try await freezeSource(
                            for: module,
                            using: freezer,
                            into: header,
                        )
                        try await writer.write(contentsOf: source.utf8)
                        try await writer.write(contentsOf: "\n".utf8)
                    }
                }

            try await writeModuleCatalogs(library.modules, to: &writer)
        }
    }

    private func freezeSource(
        for module: Module,
        using freezer: FilePath,
        into header: FilePath,
    ) async throws -> String {
        try await workspace.run(
            freezer,
            [module.name, module.source.string, header.string],
            in: workspace.outputDirectory,
            stage: "Freeze \(module.name)",
        )

        let source = try await workspace.read(textFrom: header)
        // The upstream freezer leaves '-' in sysconfig C symbols.
        guard module.name.contains("-") else {
            return source
        }

        return source.replacing(module.upstreamSymbol, with: module.symbol)
    }

    private func writeModuleCatalogs(
        _ modules: [Module],
        to writer: inout BufferedWriter<WriteFileHandle>,
    ) async throws {
        let declaration = "static const struct _frozen embedded_modules[] = {\n"
        try await writer.write(contentsOf: declaration.utf8)

        for module in modules {
            let symbol = module.symbol
            let entry = "    {\(module.name.quotedSourceLiteral), \(symbol), sizeof(\(symbol)), \(module.isPackage ? 1 : 0)},\n"
            try await writer.write(contentsOf: entry.utf8)
        }

        try await writer.write(contentsOf: """
            {NULL, NULL, 0, 0}
        };
        const struct _frozen *const CPythonEmbeddedFrozenModules = embedded_modules;
        const CPythonEmbeddedModule CPythonEmbeddedModules[] = {

        """.utf8)

        for module in modules {
            let entry = "    {\(module.name.quotedSourceLiteral), \(module.path.quotedSourceLiteral), \(module.isPackage ? 1 : 0)},\n"
            try await writer.write(contentsOf: entry.utf8)
        }

        try await writer.write(contentsOf: """
        };
        const size_t CPythonEmbeddedModuleCount =
            sizeof(CPythonEmbeddedModules) / sizeof(CPythonEmbeddedModules[0]);

        """.utf8)
    }
}

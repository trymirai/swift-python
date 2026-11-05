//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    func writeFrozenModules(_ library: Library, using freezer: FilePath) async throws {
        let output = workspace.outputDirectory
        try await workspace.fileSystem.withFileHandle(
            forWritingAt: output.appending("Frozen.c"),
            options: .newFile(replaceExisting: true),
        ) { handle in
            try await handle.withBufferedWriter { writer in
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
                        for module in library.modules {
                            if frozenHeaders.contains(module.name + ".h") {
                                continue
                            }

                            try await workspace.run(
                                freezer,
                                [module.name, module.source.string, header.string],
                                in: output,
                                stage: "Freeze \(module.name)",
                            )

                            var source = try await workspace.read(textFrom: header)
                            // The upstream freezer leaves '-' in sysconfig C symbols.
                            if module.name.contains("-") {
                                let upstreamSymbol = "_Py_M__" + module.name.replacing(
                                    ".",
                                    with: "_",
                                )
                                source = source.replacing(upstreamSymbol, with: module.symbol)
                            }

                            try await writer.write(contentsOf: source.utf8)
                            try await writer.write(contentsOf: "\n".utf8)
                        }
                    }

                let declaration = "static const struct _frozen embedded_modules[] = {\n"
                try await writer.write(contentsOf: declaration.utf8)

                for module in library.modules {
                    let entry = "    {\(module.name.quotedSourceLiteral), \(module.symbol), sizeof(\(module.symbol)), \(module.isPackage ? 1 : 0)},\n"
                    try await writer.write(contentsOf: entry.utf8)
                }

                try await writer.write(contentsOf: """
                    {NULL, NULL, 0, 0}
                };
                const struct _frozen *const CPythonEmbeddedFrozenModules = embedded_modules;
                const CPythonEmbeddedModule CPythonEmbeddedModules[] = {

                """.utf8)

                for module in library.modules {
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
    }
}

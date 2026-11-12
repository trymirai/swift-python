//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    func writePatchedSources() async throws {
        let sources: [(input: String, output: String)] = [
            ("Modules/_io/fileio.c", "FileIO.c"),
            ("Modules/posixmodule.c", "PosixModule.c"),
            ("Modules/_posixsubprocess.c", "PosixSubprocess.c"),
            ("Python/import.c", "Import.c"),
            ("Modules/socketmodule.c", "SocketModule.c"),
            ("Modules/_ssl.c", "SSLModule.c"),
            ("Modules/selectmodule.c", "SelectModule.c"),
            ("Modules/_threadmodule.c", "ThreadModule.c"),
            ("Lib/subprocess.py", "subprocess.py"),
        ]
        let patchDirectory = workspace.packageDirectory.appending("Tools/CPythonPatches")

        // Stage patches before replacing outputs so a rejected patch leaves them intact.
        try await workspace.fileSystem
            .withTemporaryDirectory(prefix: workspace.outputDirectory) { _, directory in
                try await copySources(sources, from: workspace.sourceDirectory, to: directory)

                for patch in ["FileAccess.patch", "ThreadHandles.patch", "Network.patch"] {
                    try await workspace.run(
                        "/usr/bin/patch",
                        [
                            "-s",
                            "-f",
                            "-F",
                            "0",
                            "-p1",
                            "-i",
                            patchDirectory.appending(patch).string,
                        ],
                        in: directory,
                        stage: "Apply CPython patch \(patch)",
                    )
                }

                let patched = sources.map { (input: $0.output, output: $0.output) }
                try await copySources(patched, from: directory, to: workspace.outputDirectory)
            }
    }

    private func copySources(
        _ sources: [(input: String, output: String)],
        from sourceDirectory: FilePath,
        to destinationDirectory: FilePath,
    ) async throws {
        for source in sources {
            let text = try await workspace.read(textFrom: sourceDirectory.appending(source.input))
            try await workspace.write(text, to: destinationDirectory.appending(source.output))
        }
    }
}

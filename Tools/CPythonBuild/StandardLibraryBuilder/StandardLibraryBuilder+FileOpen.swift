//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    func writeFileOpenHooks() async throws {
        try await writeFileIOHook()
        try await writePOSIXOpenHook()
    }

    private func writeFileIOHook() async throws {
        try await writeFileOpenSource(
            "Modules/_io/fileio.c",
            to: "FileIO.c",
            edits: [
                .insert("    char *swift_open_path = NULL;", after: "    const char *name = NULL;"),
                .insert("""
                #ifndef MS_WINDOWS
                            if (CPython_CheckFileOpen(name, AT_FDCWD, flags, nameobj, &swift_open_path) < 0) {
                                goto error;
                            }
                            if (swift_open_path != NULL) {
                                name = swift_open_path;
                            }
                #endif
                """, after: "        if (opener == Py_None) {"),
                .insert("""
                #else
                    PyMem_Free(swift_open_path);
                """, after: "    PyMem_Free(widename);"),
            ],
        )
    }

    private func writePOSIXOpenHook() async throws {
        try await writeFileOpenSource(
            "Modules/posixmodule.c",
            to: "PosixModule.c",
            compatibilityHeader: "Modules/posixmodule-compat.h",
            edits: [
                .insert("""

                #ifndef MS_WINDOWS
                    char *swift_open_path = NULL;
                    if (CPython_CheckFileOpen(path->narrow, dir_fd, flags, path->object, &swift_open_path) < 0) {
                        return -1;
                    }
                    const char *open_path = swift_open_path != NULL ? swift_open_path : path->narrow;
                #endif
                """, after: """
                    if (PySys_Audit("open", "OOi", path->object, Py_None, flags) < 0) {
                        return -1;
                    }
                """),
                .init(
                    anchor: "            fd = open(path->narrow, flags, mode);",
                    replacement: "            fd = open(open_path, flags, mode);",
                ),
                .insert("""

                #ifndef MS_WINDOWS
                    int saved_errno = errno;
                    PyMem_Free(swift_open_path);
                    errno = saved_errno;
                #endif
                """, after: """
                    } while (fd < 0 && errno == EINTR && !(async_err = PyErr_CheckSignals()));
                    _Py_END_SUPPRESS_IPH
                """),
            ],
        )
    }

    private func writeFileOpenSource(
        _ input: String,
        to output: String,
        compatibilityHeader: String? = nil,
        edits: [Edit],
    ) async throws {
        var source = try await workspace.read(textFrom: workspace.sourceDirectory.appending(input))

        for edit in edits {
            guard
                let range = source.firstRange(of: edit.anchor),
                source[range.upperBound...].firstRange(of: edit.anchor) == nil
            else {
                throw BuildError("Expected one file open hook site in \(input): \(edit.anchor)")
            }
            source.replaceSubrange(range, with: edit.replacement)
        }

        let prefix = compatibilityHeader.map { "#include \"\($0)\"\n" } ?? ""
        try await workspace.write(
            prefix + "#include \"file_open.h\"\n\n" + source,
            to: workspace.outputDirectory.appending(output),
        )
    }

    private struct Edit {
        let anchor: String
        let replacement: String

        static func insert(_ code: String, after anchor: String) -> Self {
            .init(anchor: anchor, replacement: anchor + "\n" + code)
        }
    }
}

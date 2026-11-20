//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    func writeGetPath() async throws {
        let upstream = workspace.sourceDirectory.appending("Modules/getpath.c")
        let source = try await workspace.read(textFrom: upstream)

        let body = source.replacing(
            "#include \"Python/frozen_modules/getpath.h\"",
            with: "#include \"Bootstrap/Python/frozen_modules/getpath.h\"",
        )

        let definitions = """
        /* Generated upstream getpath translation unit with private build macros. */
        #define PREFIX ""
        #define EXEC_PREFIX ""
        #define VERSION Py_STRINGIFY(PY_MAJOR_VERSION) "." Py_STRINGIFY(PY_MINOR_VERSION)
        #define VPATH ""
        #define PLATLIBDIR "lib"
        #define PYTHONPATH ""

        """
        let destination = workspace.outputDirectory.appending("GetPath.c")
        try await workspace.write(definitions + body, to: destination)
    }
}

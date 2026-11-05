//
//  Created by Anton Spivak
//

import SystemPackage

extension StandardLibraryBuilder {
    func writeGetPath() async throws {
        let source = workspace.sourceDirectory
        let output = workspace.outputDirectory

        let body = try await workspace
            .read(textFrom: source.appending("Modules/getpath.c"))
            .replacing(
                "#include \"Python/frozen_modules/getpath.h\"",
                with: "#include \"Bootstrap/Python/frozen_modules/getpath.h\"",
            )

        try await workspace.write("""
        /* Generated upstream getpath translation unit with private build macros. */
        #define PREFIX ""
        #define EXEC_PREFIX ""
        #define VERSION Py_STRINGIFY(PY_MAJOR_VERSION) "." Py_STRINGIFY(PY_MINOR_VERSION)
        #define VPATH ""
        #define PLATLIBDIR "lib"
        #define PYTHONPATH ""

        """ + body, to: output.appending("GetPath.c"))
    }
}

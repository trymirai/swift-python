//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Foundation
import Python
import SystemPackage
import Testing

@Test
func scriptDependenciesAndGlobalsAreIsolatedFromTheProject() async throws {
    try await ProjectFixture.withFixture { fixture in
        try await fixture.addDependencyUpdate()
        let source = """
        # /// script
        # requires-python = ">=3.13"
        # dependencies = ["sampledep==1.0"]
        # ///
        \"\"\"A standalone fixture.\"\"\"
        import sampledep, sys

        assert __name__ == "__main__"
        assert __file__ == sys.argv[0]
        counter = globals().get("counter", 0) + 1
        print(sampledep.VALUE, counter, sys.argv[1])
        """
        let script = try fixture.write("\u{FEFF}" + source, to: "script.py")
        let environment = fixture.root.appending("script-environment").string

        try await fixture.withProject { session in
            for argument in ["first", "second"] {
                let output = try await fixture.runtime.run(
                    script: script,
                    arguments: [argument],
                    environmentDirectory: environment,
                )
                #expect(output.stdout == "1 1 \(argument)\n")
            }
            #expect(try await session.installedPackages()["sampledep"] == "2.0")
        }

        try fixture.takeIndexOffline()
        let output = try await fixture.runtime.run(
            script: script,
            arguments: ["offline"],
            environmentDirectory: environment,
        )
        #expect(output.stdout == "1 1 offline\n")
    }
}

@Test
func scriptsReleaseTemporaryEnvironmentsOnExitAndFailure() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let cache = root.appending("cache")
        let runtime = try await Python::Runtime(cacheDirectory: cache.string)
        let environments = cache.appending("environments").string
        let files = FileManager.default
        try files.createDirectory(atPath: environments, withIntermediateDirectories: true)

        let script = root.appending("script.py")
        let exit = """
        print("completed")
        raise SystemExit(0)
        """
        try await exit.write(toFileAt: script)
        #expect(try await runtime.run(script: script.string).stdout == "completed\n")
        #expect(try files.contentsOfDirectory(atPath: environments).isEmpty)

        for source in ["raise SystemExit(0.0)", "if True print('invalid syntax')"] {
            try await source.write(toFileAt: script, options: .newFile(replaceExisting: true))
            await #expect(throws: Python::ExecutionError.self) {
                try await runtime.run(script: script.string)
            }
            #expect(try files.contentsOfDirectory(atPath: environments).isEmpty)
        }
    }
}

@Test(arguments: [
    "# /// script\n# requires-python = \">=99\"\n# ///\n",
    "# /// script\r\n# requires-python = \">=99\"\r\n# ///\r\n",
    "# /// script\n# dependencies = \"invalid\"\n# ///\n",
    "# /// script\n# dependencies = []\n# ///\n# /// script\n# dependencies = []\n# ///\n",
])
func invalidScriptMetadataIsRejected(_ metadata: String) async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let runtime = try await Python::Runtime(cacheDirectory: root.appending("cache").string)
        let script = root.appending("invalid.py")
        try await (metadata + "print('unexpected execution')\n").write(toFileAt: script)

        await #expect(throws: Python::Exception.self) {
            try await runtime.run(script: script.string)
        }
    }
}

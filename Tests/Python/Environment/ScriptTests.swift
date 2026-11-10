//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import Synchronization
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
        let script = try await fixture.write("\u{FEFF}" + source, to: "script.py")
        let environment = fixture.root.appending("script-environment").string

        func runScript(argument: String) async throws -> Python::Execution {
            try await fixture.runtime.run(
                script: script,
                arguments: [argument],
                environmentDirectory: environment,
            )
        }

        try await fixture.withProject { session in
            for argument in ["first", "second"] {
                let execution = try await runScript(argument: argument)
                #expect(execution.output.stdout == "1 1 \(argument)\n")
            }
            #expect(try await session.packages.installed()["sampledep"] == "2.0")
        }

        try await fixture.takeIndexOffline()
        let execution = try await runScript(argument: "offline")
        #expect(execution.output.stdout == "1 1 offline\n")
    }
}

@Test
func plainSessionAndScriptDoNotCreatePackageDirectories() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let cache = root.appending("cache")
        let runtime = try await Python::Runtime(cacheDirectory: cache.string)
        let session = try await runtime.session()
        #expect(try await session.packages.installed().isEmpty)
        #expect(try await session.evaluate("1 + 1").output.stdout == "2\n")
        await session.close()

        let script = root.appending("script.py")
        try await "print('completed')\n".write(toFileAt: script)
        let stdout = root.appending("stdout.log")
        let streamed = Mutex("")

        let execution = try await runtime.run(
            script: script.string,
            redirecting: [.stdout: stdout],
        ) { stream, text in
            if stream == .stdout {
                streamed.withLock { $0 += text }
            }
        }
        #expect(execution.end == .finished)
        #expect(execution.output.stdout.isEmpty)
        #expect(streamed.withLock { $0 } == "completed\n")
        #expect(try await String(contentsOf: stdout, maximumSizeAllowed: .unlimited) ==
            "completed\n")
        #expect(try await FileSystem.shared.info(forFileAt: cache) == nil)
    }
}

@Test
func scriptAuthorizationUsesTheApprovedSourceWithoutGrantingSiblingReads() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let script = root.appending("original.py")
        let replacement = root.appending("replacement.py")
        let link = root.appending("script.py")
        let sibling = root.appending("sibling.txt")
        try await "private".write(toFileAt: sibling)
        try await "raise AssertionError('unapproved source')\n".write(toFileAt: replacement)
        try await """
        import sys

        assert __file__ == sys.argv[0]
        assert __file__.endswith('/original.py')
        try:
            open(sys.argv[1]).close()
        except PermissionError:
            print('approved source')
        else:
            raise AssertionError('sibling read was granted')
        """.write(toFileAt: script)
        try await FileSystem.shared.createSymbolicLink(at: link, withDestination: script)

        let delegate = FileAccessDelegate { request in
            #expect(request.scope as? String == "script access")
            guard request.path.lastComponent == script.lastComponent else {
                return false
            }
            #expect(request.operation == .open(mode: .readOnly, options: []))
            #expect(request.exists)

            // Change the link after the runtime has pinned the source.
            try await FileSystem.shared.removeItem(at: link)
            try await FileSystem.shared.createSymbolicLink(at: link, withDestination: replacement)
            return true
        }
        let runtime = try await Python::Runtime()
        let result = try await runtime.run(
            script: link.string,
            scope: "script access",
            arguments: [sibling.string],
            delegate: delegate,
        )
        #expect(result.output.stdout == "approved source\n")
    }
}

@Test
func deniedScriptSourceLeavesTheEnvironmentUntouched() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let script = root.appending("script.py")
        let environment = root.appending("environment")
        try await FileSystem.shared.withFileHandle(forWritingAt: script) { handle in
            _ = try await handle.write(contentsOf: [UInt8(0xFF)], toAbsoluteOffset: 0)
        }

        let runtime = try await Python::Runtime()
        await #expect(throws: Errno.permissionDenied) {
            try await runtime.run(
                script: script.string,
                environmentDirectory: environment.string,
                delegate: FileAccessDelegate { _ in false },
            )
        }
        #expect(try await FileSystem.shared.info(forFileAt: environment) == nil)
    }
}

@Test
func scriptsReuseWheelFilesAndReleaseTemporaryEnvironments() async throws {
    try await ProjectFixture.withFixture { fixture in
        let cache = fixture.root.appending("cache")
        let scratch = cache.appending("tmp")
        let header = "# /// script\n# dependencies = [\"sampledep==1.0\"]\n# ///\n"

        func writeScript(_ source: String, named name: String) async throws -> String {
            try await fixture.write(header + source, to: name)
        }

        func expectScratchIsEmpty() async throws {
            #expect(try await ProjectFixture.directoryNames(at: scratch).isEmpty)
        }

        let script = try await writeScript("""
        from pathlib import Path
        import sampledep, sys
        assert Path(sampledep.__file__).samefile(sys.argv[1])
        assert not Path(sampledep.__file__).parents[1].joinpath("environment.json").exists()
        print("completed")
        """, named: "reuse.py")

        try await fixture.withProject { session in
            _ = try await session.evaluate("package_file = sampledep.__file__")
            let path: String = try await session.get("package_file")

            for wheel in ["sampledep", "sampleleaf"] {
                try await FileSystem.shared.removeItem(
                    at: fixture.root.appending("\(wheel)-1.0-py3-none-any.whl"),
                )
            }

            try await fixture.withProject(
                environmentDirectory: fixture.root.appending("second-environment").string,
                delegate: FileAccessDelegate {
                    $0.path == FilePath(path) && $0.operation == .metadata
                },
            ) { second in
                try await second.set(path, forKey: "first_package")
                _ = try await second.evaluate("""
                from pathlib import Path
                assert Path(sampledep.__file__).samefile(first_package)
                """)
            }

            let execution = try await fixture.runtime.run(script: script, arguments: [path])
            #expect(execution.output.stdout == "completed\n")
            try await expectScratchIsEmpty()
            #expect(try await ProjectFixture.directoryNames(at: cache.appending("wheels"))
                .count == 2)
            #expect(try await ProjectFixture.directoryNames(at: cache.appending("installed"))
                .count == 2)
        }

        let failed = try await writeScript(
            "raise ValueError('test failure')",
            named: "failure.py",
        )
        let error = try await #require(throws: Python::ExecutionError.self) {
            try await fixture.runtime.run(script: failed)
        }
        #expect(error.output.stderr == error.traceback)
        try await expectScratchIsEmpty()

        let slow = try await writeScript(
            "print('before timeout')\nwhile True:\n    pass\n",
            named: "slow.py",
        )
        let interrupted = try await fixture.runtime.run(script: slow, timeout: .seconds(2))
        #expect(interrupted.end == .timedOut)
        #expect(interrupted.output.stdout == "before timeout\n")
        try await expectScratchIsEmpty()
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

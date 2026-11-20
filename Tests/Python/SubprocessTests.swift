//
//  Created by Anton Spivak
//

#if os(macOS) || os(Linux) || targetEnvironment(macCatalyst)

import _NIOFileSystem
import Python
import Testing
#if os(macOS)
private import Darwin
#elseif canImport(Glibc)
private import Glibc
#elseif canImport(Musl)
private import Musl
#endif

// MARK: - SubprocessTests

@Suite(.timeLimit(.minutes(2)))
struct SubprocessTests {
    @Test
    func capturesOutput() async throws {
        let session = try await subprocessSession()
        defer { await session.close() }

        let execution = try await session.evaluate("""
        import subprocess

        data = b'x' * 131072
        result = subprocess.run(["/bin/cat"], input=data, capture_output=True, check=True)
        assert result.stdout == data
        assert result.stderr == b""
        print("captured")
        """)

        #expect(execution.end == .finished)
        #expect(execution.output.stdout == "captured\n")
    }

    #if os(macOS) || os(Linux)
    @Test
    func closedPipesRaiseBrokenPipeError() async {
        await #expect(processExitsWith: .success) {
            try useDefaultBrokenPipeSignal()

            let session = try await Runtime(options: [.subprocesses]).session()
            defer { await session.close() }

            let execution = try await session.evaluate("""
            import os
            import subprocess

            def expect_broken_pipe(write):
                try:
                    write(b"data")
                except BrokenPipeError:
                    pass
                else:
                    raise AssertionError("Expected a broken pipe")

            reader, writer = os.pipe()
            os.close(reader)
            with os.fdopen(writer, "wb", buffering=0) as pipe:
                expect_broken_pipe(pipe.write)
                expect_broken_pipe(lambda data: os.write(writer, data))

            with subprocess.Popen(["/bin/sh", "-c", ":"], stdin=subprocess.PIPE, bufsize=0) as child:
                assert child.wait() == 0
                expect_broken_pipe(child.stdin.write)
                expect_broken_pipe(lambda data: os.write(child.stdin.fileno(), data))
            """)

            try #require(execution.end == .finished)
            let previousHandler = signal(SIGPIPE, SIG_DFL)
            try #require(previousHandler == nil)
        }
    }
    #endif

    @Test
    func closedSubprocessOutputDeliversSIGPIPE() async throws {
        let session = try await subprocessSession()
        defer { await session.close() }

        let execution = try await session.evaluate("""
        import signal
        import subprocess

        for fd, stream in ((1, "stdout"), (2, "stderr")):
            command = ["/bin/sh", "-c", f"read ready; printf data >&{fd}"]
            with subprocess.Popen(
                command, stdin=subprocess.PIPE, **{stream: subprocess.PIPE}
            ) as child:
                getattr(child, stream).close()
                child.stdin.close()
                assert child.wait() == -signal.SIGPIPE
        """)

        #expect(execution.end == .finished)
    }

    @Test
    func defaultRuntimeDisallowsStartingAProcess() async throws {
        let runtime = try await Runtime()
        let session = try await runtime.session()
        defer { await session.close() }

        await #expect(throws: Python::Failure.self) {
            try await session.evaluate("""
            import subprocess
            _ = subprocess.run(["/bin/sh", "-c", ":"], check=True)
            """)
        }
    }

    @Test
    func runsSubprocessInAStandaloneScript() async throws {
        try await withTemporaryDirectory { directory in
            let script = directory.appending("run.py")
            try await """
            import subprocess
            print(subprocess.check_output(["/bin/sh", "-c", "printf script"]).decode())
            """.write(toFileAt: script)

            let runtime = try await Runtime(options: [.subprocesses])
            let execution = try await runtime.run(script: script.string)

            #expect(execution.end == .finished)
            #expect(execution.output.stdout == "script\n")
        }
    }

    @Test
    func waitsForChildrenBeforePublishing() async throws {
        try await withTemporaryDirectory { directory in
            let output = directory.appending("child.txt")
            let session = try await subprocessSession()
            defer { await session.close() }

            try await session.set(output.string, forKey: "path")
            let execution = try await session.evaluate(
                """
                import subprocess

                child = subprocess.Popen(["/bin/sh", "-c", 'printf done > "$1"', "sh", path])
                """,
                committing: { commit in
                    let data = try await FileSystem.shared.withFileHandle(
                        forReadingAt: output,
                    ) { handle in
                        try await handle.readToEnd(maximumSizeAllowed: .bytes(64))
                    }
                    #expect(String(decoding: data.readableBytesView, as: UTF8.self) == "done")
                    try commit.seal()
                },
            )

            #expect(execution.end == .finished)
        }
    }

    @Test
    func stopsWaitingAtTheExecutionDeadline() async throws {
        let session = try await subprocessSession()
        defer { await session.close() }

        // Load subprocess before timing the child's blocking wait.
        _ = try await session.evaluate("import subprocess")
        let execution = try await runUntilInterrupted(
            """
            import subprocess

            child = subprocess.Popen(["/bin/sleep", "30"])
            print("started")
            """,
            in: session,
            afterOutput: "started",
            delay: .seconds(3),
        )

        #expect(execution.end == .stopped)
        #expect(execution.output.stdout == "started\n")
        #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
    }

    @Test
    func cancellingTheTaskStopsTheProcessGroup() async throws {
        let session = try await subprocessSession()
        defer { await session.close() }

        // The child outlives the test limit so completion requires killing its process group.
        let execution = try await runUntilInterrupted(
            #"""
            import subprocess

            child = subprocess.Popen(
                ["/bin/sh", "-c", "sleep 300 & printf 'ready\n'; wait"],
                stdout=subprocess.PIPE,
            )
            assert child.stdout.readline() == b"ready\n"
            print("started")
            child.communicate()
            """#,
            in: session,
            afterOutput: "started",
        )

        #expect(execution.end == .stopped)
        #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
    }

    @Test
    func rejectsReturningWithALiveChildAndOpenPipe() async throws {
        let session = try await subprocessSession()
        defer { await session.close() }

        do {
            _ = try await session.evaluate("""
            import subprocess

            child = subprocess.Popen(["/bin/sleep", "30"], stdout=subprocess.PIPE)
            """)
            Issue.record("An open PIPE was accepted at the end of the execution.")
        } catch {
            #expect(String(describing: error).contains("open PIPE"))
        }

        #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
    }

    private func subprocessSession() async throws -> Session {
        try await Runtime(options: [.subprocesses]).session()
    }
}

#if os(macOS) || os(Linux)
func useDefaultBrokenPipeSignal() throws {
    _ = signal(SIGPIPE, SIG_DFL)
    var signals = sigset_t()
    unsafe sigemptyset(&signals)
    unsafe sigaddset(&signals, SIGPIPE)
    let status = unsafe pthread_sigmask(SIG_UNBLOCK, &signals, nil)
    try #require(status == 0)
}
#endif

#endif

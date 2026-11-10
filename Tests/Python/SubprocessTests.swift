//
//  Created by Anton Spivak
//

#if os(macOS) || os(Linux) || targetEnvironment(macCatalyst)

import _NIOFileSystem
import Python
import Testing

// MARK: - SubprocessTests

@Suite(.timeLimit(.minutes(2)))
struct SubprocessTests {
    @Test
    func capturesOutputInATransaction() async throws {
        let session = try await transactionalSession()
        defer { await session.close() }

        let execution = try await session.evaluate(
            """
            import subprocess

            data = b'x' * 131072
            result = subprocess.run(["/bin/cat"], input=data, capture_output=True, check=True)
            assert result.stdout == data
            assert result.stderr == b""
            print("captured")
            """,
        )

        #expect(execution.end == .finished)
        #expect(execution.output.stdout == "captured\n")
    }

    @Test
    func defaultRuntimeDisallowsStartingAProcess() async throws {
        let runtime = try await Runtime()
        let session = try await runtime.session()
        defer { await session.close() }

        await #expect(throws: ExecutionError.self) {
            try await session.evaluate("""
            import subprocess
            _ = subprocess.run(["/bin/sh", "-c", ":"], check=True)
            """)
        }
    }

    @Test
    func runsSubprocessInAStandaloneScript() async throws {
        try await FileSystem.shared.withTemporaryDirectory { _, directory in
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
        try await FileSystem.shared.withTemporaryDirectory { _, directory in
            let output = directory.appending("child.txt")
            let session = try await transactionalSession()
            defer { await session.close() }

            try await session.set(output.string, forKey: "path")
            let execution = try await session.evaluate(
                """
                import subprocess

                child = subprocess.Popen(["/bin/sh", "-c", 'printf done > "$1"', "sh", path])
                """,
                committing: { commit in
                    let data = try await FileSystem.shared.withFileHandle(forReadingAt: output) {
                        try await $0.readToEnd(maximumSizeAllowed: .bytes(64))
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
        let session = try await transactionalSession()
        defer { await session.close() }

        _ = try await session.evaluate("import subprocess")
        let execution = try await session.evaluate(
            """
            import subprocess

            child = subprocess.Popen(["/bin/sleep", "30"])
            print("started")
            """,
            timeout: .seconds(3),
        )

        #expect(execution.end == .timedOut)
        #expect(execution.output.stdout == "started\n")
        #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
    }

    @Test(arguments: [false, true])
    func interruptionStopsTheProcessGroup(cancelTask: Bool) async throws {
        let session = try await transactionalSession()
        defer { await session.close() }

        let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { signal.finish() }
            return try await session.evaluate(
                #"""
                import subprocess

                child = subprocess.Popen(
                    ["/bin/sh", "-c", "sleep 60 & printf 'ready\n'; wait"],
                    stdout=subprocess.PIPE,
                )
                assert child.stdout.readline() == b"ready\n"
                print("started")
                child.communicate()
                """#,
            ) { stream, text in
                if stream == .stdout, text.contains("started") {
                    signal.yield(())
                }
            }
        }
        defer { task.cancel() }

        _ = try await #require(nextSignal(from: started))
        let cancellation = ContinuousClock.now
        if cancelTask {
            task.cancel()
        } else {
            #expect(session.stop())
        }

        #expect(try await task.value.end == .stopped)
        #expect(cancellation.duration(to: .now) < .seconds(15))
        #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
    }

    @Test
    func rejectsReturningWithALiveChildAndOpenPipe() async throws {
        let session = try await transactionalSession()
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

    private func transactionalSession() async throws -> Session {
        try await Runtime(options: [.subprocesses]).session(transactional: true)
    }
}

#endif

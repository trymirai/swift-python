//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import Synchronization
import SystemPackage
import Testing

@Test
func fileBackedStreamsAppendAndReadFromOffsets() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let input = root.appending("stdin")
        let stdout = root.appending("stdout.log")
        let stderr = root.appending("stderr.log")
        let startup = root.appending("startup.log")

        let messageWidth = 2048
        try await "input from file\n".write(toFileAt: input)
        let redirects: [Python::Session.Stream: FilePath] = [
            .stdin: input,
            .stdout: stdout,
            .stderr: stderr,
        ]
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(
            .source("print('initialized')"),
            redirecting: [.stdout: startup],
        )
        #expect(await session.startupOutput?.stdout == "")
        #expect(try await readOutput(at: startup) == Array("initialized\n".utf8))

        let execution = try await session.evaluate(#"""
        import logging, sys

        print(input())
        _ = sys.stdout.buffer.write(b"\x00\xff")
        sys.stdout.flush()
        print("HEAD" + "x" * \#(messageWidth) + "TAIL")
        logger = logging.getLogger("streams-test")
        logger.addHandler(logging.StreamHandler(sys.stderr))
        logger.warning("first diagnostic")
        """#, redirecting: redirects)
        #expect(execution.output.stdout.isEmpty)
        #expect(execution.output.stderr.isEmpty)

        let firstBytes = try await readOutput(at: stdout)
        let text = "HEAD" + String(repeating: "x", count: messageWidth) + "TAIL\n"
        let expectedBytes = Array("input from file\n".utf8) + [0x00, 0xFF] + Array(text.utf8)
        #expect(firstBytes == expectedBytes)
        #expect(try await readOutput(at: stderr) == Array("first diagnostic\n".utf8))

        let next = try await session.evaluate(
            "print('next'); logger.warning('second diagnostic')",
            redirecting: redirects,
        )
        #expect(next.output.stdout.isEmpty)
        #expect(next.output.stderr.isEmpty)
        let appended = try await readOutput(at: stdout, from: Int64(firstBytes.count))
        #expect(appended == Array("next\n".utf8))
        #expect(try await readOutput(at: stderr) ==
            Array("first diagnostic\nsecond diagnostic\n".utf8))
        await session.close()
    }
}

@Test
func fileBackedStreamsUseHostFileAccess() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let stdout = root.appending("stdout.log")
        let runtime = try await Python::Runtime()
        let session = try await runtime.session()
        _ = try await session.evaluate("""
        import builtins, io

        def managed_open(*args, **kwargs):
            raise PermissionError("managed file access")

        builtins.open = io.open = managed_open
        """, redirecting: [.stdout: stdout])
        _ = try await session.evaluate("""
        print("host stream")
        try:
            open("/unapproved")
        except PermissionError:
            pass
        else:
            raise AssertionError("The user file adapter was bypassed")
        """, redirecting: [.stdout: stdout])
        #expect(try await readOutput(at: stdout) == Array("host stream\n".utf8))
        await session.close()
    }
}

@Test
func redirectedOutputAndTracebackReachHostOnFailure() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let stdout = root.appending("stdout.log")
        let stderr = root.appending("stderr.log")
        let streamed = Mutex("")
        let runtime = try await Python::Runtime()
        let session = try await runtime.session()
        let error = try await #require(throws: Python::ExecutionError.self) {
            try await session.evaluate(
                """
                import sys
                print('before failure')
                print('diagnostic', file=sys.stderr)
                raise ValueError('failure')
                """,
                redirecting: [.stdout: stdout, .stderr: stderr],
            ) { stream, text in
                if stream == .stderr {
                    streamed.withLock { $0 += text }
                }
            }
        }
        #expect(error.output.stdout.isEmpty)
        #expect(error.output.stderr.isEmpty)
        #expect(error.traceback.contains("ValueError: failure"))
        let diagnostics = "diagnostic\n" + error.traceback
        #expect(try await readOutput(at: stderr) == Array(diagnostics.utf8))
        #expect(streamed.withLock { $0 } == diagnostics)
        #expect(try await readOutput(at: stdout) == Array("before failure\n".utf8))
        await session.close()
    }
}

@Test
func capturedStreamsRecoverAfterCloseAndReadEOFWithoutInput() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()

    let captured = try await session.evaluate("""
    import sys
    print('x' * 131072)
    sys.stdout.close()
    """)
    #expect(captured.output.stdout == String(repeating: "x", count: 131_072) + "\n")
    #expect(try await session.evaluate("'alive'").output.stdout == "'alive'\n")
    await #expect {
        try await session.evaluate("sys.stderr.close(); input()")
    } throws: { error in
        (error as? Python::ExecutionError)?.traceback.contains("EOFError") == true
    }
    await session.close()
}

@Test(.timeLimit(.minutes(1)))
func readStreamsDuringExecution() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            entered.continuation.finish()
            gate.continuation.finish()
        }
        let wait = Python::Module.Function("wait") { _ in
            entered.continuation.yield(())
            _ = await nextSignal(from: gate.stream)
            try Task.checkCancellation()
            return .none
        }
        let runtime = try await Python::Runtime()
        let host = Python::Module("host", functions: [wait])
        let session = try await runtime.session(moduleDefinitions: [host])
        let stdout = root.appending("stdout.log")
        let evaluation = Task {
            try await session.evaluate("""
            import host
            print("ready", flush=True)
            await host.wait()
            print("finished")
            """, redirecting: [.stdout: stdout])
        }
        defer { evaluation.cancel() }

        _ = try await #require(nextSignal(from: entered.stream))

        #expect(session.isRunning)
        let prefix = try await readOutput(at: stdout)
        #expect(prefix == Array("ready\n".utf8))

        gate.continuation.yield(())
        #expect(try await evaluation.value.output.stdout.isEmpty)
        let suffix = try await readOutput(at: stdout, from: Int64(prefix.count))
        #expect(suffix == Array("finished\n".utf8))
        await session.close()
    }
}

private func readOutput(at path: FilePath, from offset: Int64 = 0) async throws -> [UInt8] {
    try await FileSystem.shared.withFileHandle(forReadingAt: path) { handle in
        let bytes = try await handle.readChunk(
            fromAbsoluteOffset: offset,
            length: .bytes(64 * 1024),
        )
        return Array(bytes.readableBytesView)
    }
}

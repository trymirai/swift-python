//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

@Test
func fileBackedStreamsAppendAndReadFromOffsets() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let input = root.appending("stdin")
        try await "input from file\n".write(toFileAt: input)
        let streams = Python::StandardIO(
            stdin: input.string,
            stdout: root.appending("stdout.log").string,
            stderr: root.appending("stderr.log").string,
        )
        let startup = Python::StandardIO(stdout: root.appending("startup.log").string)
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(
            .source("print('initialized')"),
            startupIO: startup,
        )
        #expect(await session.startupOutput?.stdout == "")
        #expect(try await startup.read(.stdout) == Array("initialized\n".utf8))

        let output = try await session.evaluate(#"""
        import logging, sys

        print(input())
        _ = sys.stdout.buffer.write(b"\x00\xff")
        sys.stdout.flush()
        print("HEAD" + "x" * 2048 + "TAIL")
        logger = logging.getLogger("streams-test")
        logger.addHandler(logging.StreamHandler(sys.stderr))
        logger.warning("first diagnostic")
        """#, standardIO: streams)
        #expect(output.stdout.isEmpty)
        #expect(output.stderr.isEmpty)

        let firstBytes = try await streams.read(.stdout, maximumByteCount: 4096)
        let text = "HEAD" + String(repeating: "x", count: 2048) + "TAIL\n"
        let expectedBytes = Array("input from file\n".utf8) + [0x00, 0xFF] + Array(text.utf8)
        #expect(firstBytes == expectedBytes)
        #expect(try await streams.read(.stderr) == Array("first diagnostic\n".utf8))

        let next = try await session.evaluate(
            "print('next'); logger.warning('second diagnostic')",
            standardIO: streams,
        )
        #expect(next.stdout.isEmpty)
        #expect(next.stderr.isEmpty)
        let appended = try await streams.read(.stdout, from: Int64(firstBytes.count))
        #expect(appended == Array("next\n".utf8))
        #expect(try await streams
            .read(.stderr) == Array("first diagnostic\nsecond diagnostic\n".utf8))
        await session.close()
    }
}

@Test
func fileBackedStreamsUseHostFileAccess() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let streams = Python::StandardIO(stdout: root.appending("stdout.log").string)
        let runtime = try await Python::Runtime()
        let session = try await runtime.session()
        _ = try await session.evaluate("""
        import builtins, io

        def managed_open(*args, **kwargs):
            raise PermissionError("managed file access")

        builtins.open = io.open = managed_open
        """, standardIO: streams)
        _ = try await session.evaluate("""
        print("host stream")
        try:
            open("/unapproved")
        except PermissionError:
            pass
        else:
            raise AssertionError("The user file adapter was bypassed")
        """, standardIO: streams)
        #expect(try await streams.read(.stdout) == Array("host stream\n".utf8))
        await session.close()
    }
}

@Test
func fileBackedStreamsRecordTracebackAndOutputOnFailure() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, root in
        let tracebackFile = root.appending("traceback.txt")
        let streams = Python::StandardIO(
            stdout: root.appending("stdout.log").string,
            traceback: tracebackFile.string,
        )
        let runtime = try await Python::Runtime()
        let session = try await runtime.session()
        let error = try await #require(throws: Python::ExecutionError.self) {
            try await session.evaluate(
                "print('before failure'); raise ValueError('failure')",
                standardIO: streams,
            )
        }
        if case let .exception(traceback, output) = error {
            #expect(output.stdout.isEmpty)
            #expect(traceback.contains("ValueError: failure"))
            let recorded = try await String(
                contentsOf: tracebackFile,
                maximumSizeAllowed: .unlimited,
            )
            #expect(recorded == traceback)
        } else {
            Issue.record("Expected a Python traceback, got \(error)")
        }
        #expect(try await streams.read(.stdout) == Array("before failure\n".utf8))
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
    #expect(captured.stdout == String(repeating: "x", count: 131_072) + "\n")
    #expect(try await session.evaluate("'alive'").stdout == "'alive'\n")
    await #expect {
        try await session.evaluate("input()")
    } throws: { error in
        guard case let .exception(traceback, _)? = error as? Python::ExecutionError else {
            return false
        }
        return traceback.contains("EOFError")
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
            for await _ in gate.stream {
                break
            }
            try Task.checkCancellation()
            return .none
        }
        let runtime = try await Python::Runtime()
        let host = Python::Module("host", functions: [wait])
        let session = try await runtime.session(moduleDefinitions: [host])
        let streams = Python::StandardIO(stdout: root.appending("stdout.log").string)
        let evaluation = Task {
            try await session.evaluate("""
            import host
            print("ready", flush=True)
            await host.wait()
            print("finished")
            """, standardIO: streams)
        }
        defer { evaluation.cancel() }
        var ready = entered.stream.makeAsyncIterator()
        let enteredCallback: Void? = await ready.next()
        try #require(enteredCallback != nil)

        #expect(session.isRunning)
        let prefix = try await streams.read(.stdout)
        #expect(prefix == Array("ready\n".utf8))

        gate.continuation.yield(())
        #expect(try await evaluation.value.stdout.isEmpty)
        let suffix = try await streams.read(.stdout, from: Int64(prefix.count))
        #expect(suffix == Array("finished\n".utf8))
        await session.close()
    }
}

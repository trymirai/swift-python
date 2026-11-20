//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

// MARK: - RecordingFileAccessDelegate

private actor RecordingFileAccessDelegate: Python::Session.Delegate {
    static let readableName: String = "delegate-readable.txt"
    static let protectedName: String = "delegate-protected.txt"
    static let scriptName: String = "script.py"

    private(set) var requests: [Python::Session.FileAccessRequest] = []

    func shouldAllowFileAccess(_ request: Python::Session.FileAccessRequest) async throws -> Bool {
        guard
            case let .open(mode, _) = request.operation,
            let name = request.path.lastComponent?.string,
            name == Self.readableName || name == Self.protectedName || name == Self.scriptName
        else {
            return true
        }
        await Task.yield()
        preconditionIsolated()
        requests.append(request)
        return name != Self.protectedName || mode == .readOnly
    }
}

@Test(.timeLimit(.minutes(1)))
func sessionDelegateChecksNativeFileOpens() async throws {
    try await withTemporaryDirectory { directory in
        let readableName = RecordingFileAccessDelegate.readableName
        let protectedName = RecordingFileAccessDelegate.protectedName
        let readable = directory.appending(readableName)
        let protected = directory.appending(protectedName)

        try await "readable".write(toFileAt: readable)
        try await "keep".write(toFileAt: protected)

        let delegate = RecordingFileAccessDelegate()
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(delegate: delegate)
        defer { await session.close() }

        try await session.set(directory.string, forKey: "directory")
        _ = try await session.evaluate(
            """
            import errno, io, os, sys
            from pathlib import Path

            base = os.path.realpath(directory)
            readable = Path(base, '\(readableName)')
            protected = Path(base, '\(protectedName)')

            assert readable.read_text() == 'readable'
            with open(readable, opener=lambda path, flags: os.open(path, flags)) as f:
                assert isinstance(f, io.TextIOWrapper) and f.read() == 'readable'

            directory_fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
            try:
                fd = os.open(b'\(readableName)', os.O_RDWR | os.O_APPEND, dir_fd=directory_fd)
                with io.FileIO(fd, 'rb') as f:
                    assert f.read() == b'readable'
            finally:
                os.close(directory_fd)

            sys.audit('open', str(protected), 'w', os.O_WRONLY | os.O_TRUNC)
            try:
                open(protected, 'w')
            except PermissionError as error:
                assert error.errno == errno.EACCES and error.filename == str(protected)
            else:
                raise AssertionError('expected delegate to veto truncation')
            assert protected.read_text() == 'keep'
            """,
            scope: "file access",
        )

        let base: String = try await session.get("base")
        let requests = await delegate.requests
        try checkFileAccessRequests(requests, relativeTo: FilePath(base))
        #expect(requests.allSatisfy { $0.scope as? String == "file access" })

        _ = try await session.evaluate("assert readable.read_text() == 'readable'")
        #expect(await delegate.requests.last?.scope == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func hostStreamsBypassPathOpenDelegate() async throws {
    try await withTemporaryDirectory { directory in
        let input = directory.appending(RecordingFileAccessDelegate.readableName)
        let log = directory.appending(RecordingFileAccessDelegate.protectedName)
        try await "input\n".write(toFileAt: input)
        try await "previous\n".write(toFileAt: log)

        let delegate = RecordingFileAccessDelegate()
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(
            .source("print('startup')"),
            delegate: delegate,
        )
        defer { await session.close() }

        try await session.initialize(redirecting: [.stdout: log])
        try await session.set(log.string, forKey: "log")
        let execution = try await session.evaluate(
            #"""
            import sys

            assert sys.stdin.read() == "input\n"
            print("stdout")
            _ = sys.stderr.buffer.write(b"stderr\n")
            sys.stderr.buffer.flush()
            try:
                open(log, "a")
            except PermissionError:
                pass
            else:
                raise AssertionError("Expected ordinary append to reach the delegate")
            """#,
            redirecting: [.stdin: input, .stdout: log, .stderr: log],
        )

        #expect(execution.end == .finished)
        #expect(execution.output.stdout.isEmpty && execution.output.stderr.isEmpty)
        #expect(try await readText(at: log) == "previous\nstartup\nstdout\nstderr\n")

        let requests = await delegate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.path == log)
        #expect(requests.first?.operation.openParameters?.options.contains(.append) == true)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func sessionCallsRestoreStreamsAfterPythonReturnsOrThrows(_ fail: Bool) async throws {
    let session = try await Python::Runtime().session(
        .source(noisyCallSource),
        delegate: RecordingFileAccessDelegate(),
    )
    defer { await session.close() }

    func callStreamFunction(_ name: String) async throws {
        try await session.enqueue { context in
            try context.object(name)().decode(as: Void.self)
        }
    }

    func callNoisy() async throws -> Int {
        try await callPythonFunction("noisy", in: session, arguments: [fail], as: Int.self)
    }

    try await callStreamFunction("remember_streams")
    if fail {
        let exception = try await expectPythonFailure(.exception(.valueError)) {
            _ = try await callNoisy()
        }
        #expect(exception.message == "native failure")
    } else {
        #expect(try await callNoisy() == 42)
    }

    try await callStreamFunction("check_streams")

    let execution = try await session.evaluate(#"""
    print("repl stdout")
    _ = sys.stderr.buffer.write(b"repl stderr\n")
    sys.stderr.buffer.flush()
    """#)
    #expect(execution.output.stdout == "repl stdout\n")
    #expect(execution.output.stderr == "repl stderr\n")
}

private let noisyCallSource = #"""
import asyncio
import sys

def remember_streams():
    global original_streams
    original_streams = (sys.stdin, sys.stdout, sys.stderr)

def check_streams():
    assert (sys.stdin, sys.stdout, sys.stderr) == original_streams

async def noisy(fail):
    print("native stdout", flush=True)
    sys.stderr.buffer.write(b"native stderr\n")
    sys.stderr.buffer.flush()
    assert sys.stdin.read() == ""

    await asyncio.sleep(0)
    print("after await", flush=True)
    if fail:
        raise ValueError("native failure")
    return 42
"""#

@Test(.timeLimit(.minutes(1)))
func standaloneScriptUsesOneDelegateForSourceAndPythonFileAccess() async throws {
    try await withTemporaryDirectory { directory in
        let script = directory.appending(RecordingFileAccessDelegate.scriptName)
        let protected = directory.appending(RecordingFileAccessDelegate.protectedName)
        try await "keep".write(toFileAt: protected)
        try await """
        import sys

        with open(sys.argv[1], "w") as file:
            file.write("unexpected")
        """.write(toFileAt: script)

        let delegate = RecordingFileAccessDelegate()
        let runtime = try await Python::Runtime()
        let error = try await #require(throws: Python::Failure.self) {
            try await runtime.run(
                script: script.string,
                arguments: [protected.string],
                delegate: delegate,
            )
        }
        #expect(error.traceback?.contains("PermissionError") == true)
        #expect(try await readText(at: protected) == "keep")

        let requests = await delegate.requests
        let names = requests.map(\.path.lastComponent)
        #expect(names == [script.lastComponent, protected.lastComponent])
        #expect(requests.first?.operation == .open(mode: .readOnly, options: []))
        let write = requests.last?.operation.openParameters
        #expect(write?.mode == .writeOnly)
        #expect(write?.options.contains(.truncate) == true)
    }
}

private func checkFileAccessRequests(
    _ requests: [Python::Session.FileAccessRequest],
    relativeTo root: FilePath,
) throws {
    let readable = root.appending(RecordingFileAccessDelegate.readableName)
    let protected = root.appending(RecordingFileAccessDelegate.protectedName)

    #expect(requests.map(\.path) == [readable, readable, readable, protected, protected])
    let modes = requests.compactMap { $0.operation.openParameters?.mode }
    #expect(modes == [.readOnly, .readOnly, .readWrite, .writeOnly, .readOnly])

    let append = try #require(requests.dropFirst(2).first)
    #expect(append.operation.openParameters?.options.contains(.append) == true)

    let truncate = try #require(requests.dropFirst(3).first)
    #expect(truncate.operation.openParameters?.options.contains([.create, .truncate]) == true)
}

// MARK: - SuspendedFileAccessDelegate

private actor SuspendedFileAccessDelegate: Python::Session.Delegate {
    let path: FilePath
    let entered: AsyncStream<Void>.Continuation

    private let suspended: AsyncStream<Void> = .init { _ in }
    private(set) var cancelled: Bool = false

    init(path: FilePath, entered: AsyncStream<Void>.Continuation) {
        self.path = path
        self.entered = entered
    }

    func shouldAllowFileAccess(_ request: Python::Session.FileAccessRequest) async throws -> Bool {
        guard request.path == path else {
            return true
        }

        entered.yield(())
        defer { cancelled = Task.isCancelled }

        for await _ in suspended {}
        try Task.checkCancellation()
        return true
    }
}

@Test(.timeLimit(.minutes(1)))
func fileOpenInterruptionJoinsDelegate() async throws {
    try await withTemporaryDirectory { directory in
        let path = directory.appending("delegate-cancelled.txt")
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { entered.continuation.finish() }

        let delegate = SuspendedFileAccessDelegate(path: path, entered: entered.continuation)
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(delegate: delegate)
        defer { await session.close() }

        try await session.set(path.string, forKey: "path")

        let source = """
        print('before open')
        with open(path, 'w') as f:
            f.write('unexpected')
        """
        let execution = try await runUntilInterrupted(whenReady: entered) {
            // Cancelling the parent must also interrupt its child evaluation.
            try await withThrowingTaskGroup(of: Python::Execution.self) { group in
                group.addTask { try await session.evaluate(source) }
                return try await #require(group.next())
            }
        }
        #expect(execution.end == .stopped)
        #expect(execution.output.stdout == "before open\n")
        #expect(execution.output.stderr.isEmpty)
        #expect(await delegate.cancelled)
        #expect(try await FileSystem.shared.info(forFileAt: path) == nil)
        #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func closingASessionPreservesItsFileAccessPolicy(hasDelegate: Bool) async throws {
    try await withTemporaryDirectory { directory in
        let protected = directory.appending(RecordingFileAccessDelegate.protectedName)
        try await "keep".write(toFileAt: protected)

        let delegate = RecordingFileAccessDelegate()
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(delegate: hasDelegate ? delegate : nil)
        defer { await session.close() }
        try await session.set(protected.string, forKey: "protected")
        let execution = try await session.evaluate("""
        import atexit

        def cleanup(path, open_file=open):
            try:
                with open_file(path, "w") as file:
                    file.write("exit handler")
            except PermissionError:
                pass

        atexit.register(cleanup, protected)
        """)
        #expect(execution.end == .finished)

        // The exit handler attempts its write during close, outside any execution block.
        await session.close()
        let actual = try await readText(at: protected)
        #expect(actual == "keep")
        #expect(await delegate.requests.isEmpty)
    }
}

private extension Python::Session.FileAccessRequest.Operation {
    var openParameters: (mode: FileDescriptor.AccessMode, options: FileDescriptor.OpenOptions)? {
        guard case let .open(mode, options) = self else {
            return nil
        }

        return (mode, options)
    }
}

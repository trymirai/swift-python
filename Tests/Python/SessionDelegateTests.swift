//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import SystemPackage
import Testing

// MARK: - RecordingFileOpenDelegate

private actor RecordingFileOpenDelegate: Python::Session.Delegate {
    static let readableName: String = "delegate-readable.txt"
    static let protectedName: String = "delegate-protected.txt"

    private(set) var requests: [Python::Session.FileOpenRequest] = []

    func session(
        _ session: Python::Session,
        shouldOpenFile request: Python::Session.FileOpenRequest,
    ) async throws -> Bool {
        guard
            let name = request.path.lastComponent?.string,
            name == Self.readableName || name == Self.protectedName
        else {
            return true
        }
        await Task.yield()
        preconditionIsolated()
        requests.append(request)
        return name != Self.protectedName || request.mode == .readOnly
    }
}

@Test(.timeLimit(.minutes(1)))
func sessionDelegateChecksNativeFileOpens() async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, directory in
        let readableName = RecordingFileOpenDelegate.readableName
        let protectedName = RecordingFileOpenDelegate.protectedName
        let readable = directory.appending(readableName)
        let protected = directory.appending(protectedName)

        try await "readable".write(toFileAt: readable)
        try await "keep".write(toFileAt: protected)

        let delegate = RecordingFileOpenDelegate()
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(delegate: delegate)
        try await session.set(directory.string, forKey: "directory")
        _ = try await session.evaluate("""
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
        """)

        let base: String = try await session.get("base")
        try await checkFileOpenRequests(delegate.requests, relativeTo: FilePath(base))

        let ordinary = try await runtime.session()
        try await ordinary.set(protected.string, forKey: "protected")
        _ = try await ordinary
            .evaluate("with open(protected, 'w') as f: f.write('ordinary session')")
        await ordinary.close()
        await session.close()
    }
}

private func checkFileOpenRequests(
    _ requests: [Python::Session.FileOpenRequest],
    relativeTo root: FilePath,
) throws {
    let readable = root.appending(RecordingFileOpenDelegate.readableName)
    let protected = root.appending(RecordingFileOpenDelegate.protectedName)

    #expect(requests.map(\.path) == [readable, readable, readable, protected, protected])
    #expect(requests.map(\.mode) == [.readOnly, .readOnly, .readWrite, .writeOnly, .readOnly])

    let append = try #require(requests.dropFirst(2).first)
    #expect(append.options.contains(.append))
    let truncate = try #require(requests.dropFirst(3).first)
    #expect(truncate.options.contains([.create, .truncate]))
}

// MARK: - SuspendedFileOpenDelegate

private actor SuspendedFileOpenDelegate: Python::Session.Delegate {
    let path: FilePath
    let entered: AsyncStream<Void>.Continuation

    private(set) var cancelled = false

    init(path: FilePath, entered: AsyncStream<Void>.Continuation) {
        self.path = path
        self.entered = entered
    }

    func session(
        _ session: Python::Session,
        shouldOpenFile request: Python::Session.FileOpenRequest,
    ) async throws -> Bool {
        guard request.path == path else {
            return true
        }
        entered.yield(())
        defer { cancelled = Task.isCancelled }
        try await Task.sleep(for: .seconds(30))
        return true
    }
}

// MARK: - FileOpenInterruption

private enum FileOpenInterruption: CaseIterable {
    case cancelParent
    case stop
    case timeout
}

@Test(.timeLimit(.minutes(1)), arguments: FileOpenInterruption.allCases)
private func fileOpenInterruptionJoinsDelegate(_ interruption: FileOpenInterruption) async throws {
    try await FileSystem.shared.withTemporaryDirectory { _, directory in
        let path = directory.appending("delegate-cancelled.txt")
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { entered.continuation.finish() }

        let delegate = SuspendedFileOpenDelegate(path: path, entered: entered.continuation)
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(delegate: delegate)
        try await session.set(path.string, forKey: "path")

        let source = """
        print('before open')
        with open(path, 'w') as f:
            f.write('unexpected')
        """
        let timeout: Duration? = interruption == .timeout ? .seconds(2) : nil
        let evaluation = Task {
            defer { entered.continuation.finish() }
            return try await withThrowingTaskGroup(of: Python::Execution.self) { group in
                group.addTask {
                    try await session.evaluate(source, timeout: timeout)
                }
                return try await #require(group.next())
            }
        }
        defer { evaluation.cancel() }

        if interruption != .timeout {
            _ = try await #require(nextSignal(from: entered.stream))
            if interruption == .stop {
                #expect(session.stop())
            } else {
                evaluation.cancel()
            }
        }

        let execution = try await evaluation.value
        #expect(execution.end == (interruption == .timeout ? .timedOut : .stopped))
        #expect(execution.output.stdout == "before open\n")
        #expect(execution.output.stderr.isEmpty)
        #expect(await delegate.cancelled)
        #expect(try await FileSystem.shared.info(forFileAt: path) == nil)
        #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
        await session.close()
    }
}

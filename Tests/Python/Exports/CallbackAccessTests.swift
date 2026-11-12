//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import Synchronization
import SystemPackage
import Testing

// MARK: - CallbackAccess

@PythonExportedModule("callback_access")
private enum CallbackAccess {
    @PythonFunction
    static func sum(_ first: Int, _ second: Int) -> Int {
        first + second
    }

    @PythonFunction
    static func members(_ date: Python::DateTime, counter: AccessCounter) async throws -> [Int] {
        let year = try date.year
        await Task.yield()
        try counter.$value { $0 + 1 }
        let parsed = try Python::Date.fromISOFormat("2024-02-29")
        return try [year, date.month, counter.value, parsed.day]
    }

    @PythonFunction
    static func inspect(
        _ python: Python::Context,
        _ date: Python::DateTime,
        counter: AccessCounter,
    ) async throws -> [Int] {
        let year = try date.year
        try counter.$value { $0 + 1 }
        await Task.yield()
        let month = try date.month
        try await python.set(year, forKey: "callback_year")
        let saved = try await python.get("callback_year", as: Int.self)
        try await python.remove("callback_year")
        let created = try Python::DateTime(year: year, month: month, day: 1, in: python)
        let path = try Python::Path("reports/today.txt", in: python)
        guard try path.name == "today.txt", try created.day == 1, saved == year else {
            throw Python::Exception(name: "ValueError", message: "Unexpected native value.")
        }
        return try [year, month, counter.value]
    }

    @PythonFunction("read_text")
    static func readText(_ path: AccessPath) async throws -> String {
        await Task.yield()
        return try path.readText()
    }

    @PythonFunction
    static func spin(_ value: AccessRunner) async throws {
        await Task.yield()
        try value.spin()
    }

    @PythonFunction("spin_swift")
    static func spinSwift(_ python: Python::Context) throws {
        try started(python)
        while true {
            try Task.checkCancellation()
        }
    }

    @PythonFunction
    static func started(_ python: Python::Context) throws {
        let signal: AsyncStream<Void>.Continuation = try requireScope(
            python,
            message: "Missing test signal.",
        )
        signal.yield()
    }

    @PythonFunction("saved_year")
    static func savedYear(_ python: Python::Context) async throws -> Int {
        let date: Python::DateTime = try requireScope(python, message: "Missing date.")
        await Task.yield()
        return try date.year
    }

    @PythonFunction
    static func hold(_ python: Python::Context, _ descriptor: Int) async throws {
        let capture: RetainedCallback = try requireScope(python)
        await Task.yield()
        capture.state.withLock { $0 = (python, descriptor) }
    }

    @PythonFunction
    static func escape(_ python: Python::Context, _ date: Python::DateTime) async throws {
        let capture: EscapedCallback = try requireScope(python)
        capture.start { try date.year }
    }

    @PythonFunction
    static func expired(_ python: Python::Context) async throws -> Bool {
        let capture: EscapedCallback = try requireScope(python, message: "Missing escaped task.")
        guard let task = capture.task.withLock({ $0 }) else {
            throw Python::Exception(name: "ValueError", message: "Missing escaped task.")
        }
        capture.gate.continuation.finish()
        do {
            _ = try await task.value
            return false
        } catch Python::Session.Error.closed {
            return true
        }
    }

    @PythonFunction("escape_sync")
    static func escapeSynchronously(_ python: Python::Context) throws {
        let capture: EscapedCallback = try requireScope(python)
        capture.start { try Python::Date.today().year }
    }

    @PythonFunction
    static func nested(_ python: Python::Context) async throws -> Bool {
        let capture: EscapedCallback = try requireScope(python, message: "Missing nested session.")
        guard let other = capture.session else {
            throw Python::Exception(name: "ValueError", message: "Missing nested session.")
        }
        _ = try await other.evaluate(
            "from callback_access import escape_sync; escape_sync()",
            scope: capture,
            in: python,
        )
        return try await expired(python)
    }

    private static func requireScope<Value>(
        _ context: Python::Context,
        message: String = "Missing test capture.",
    ) throws -> Value {
        guard let value = context.scope as? Value else {
            throw Python::Exception(name: "ValueError", message: message)
        }
        return value
    }
}

// MARK: - AccessCounter

@PythonExportedClass("Counter", module: CallbackAccess.self)
private final class AccessCounter: Sendable {
    @PythonProperty
    var value: Int

    @PythonInit
    init(_ value: Int) throws {
        try $value(value)
    }
}

// MARK: - AccessPath

@PythonImportedClass(module: "pathlib", name: "Path")
private struct AccessPath {
    @PythonFunction("read_text")
    func readText() throws -> String
}

// MARK: - AccessRunner

@PythonImportedClass(module: "builtins", name: "object")
private struct AccessRunner {
    @PythonFunction
    func spin() throws
}

// MARK: - RetainedCallback

private final class RetainedCallback: Sendable {
    let state: Mutex<(Python::Context, Int)?> = .init(nil)
}

// MARK: - EscapedCallback

private final class EscapedCallback: Sendable {
    let session: Python::Session?

    let gate: (
        stream: AsyncStream<Void>,
        continuation: AsyncStream<Void>.Continuation,
    ) = AsyncStream<Void>
        .makeStream()

    let task: Mutex<Task<Int, any Swift::Error>?> = .init(nil)

    init(session: Python::Session? = nil) {
        self.session = session
    }

    func start(_ operation: @escaping @Sendable () throws -> Int) {
        let task = Task {
            for await _ in self.gate.stream {}
            return try operation()
        }
        self.task.withLock { $0 = task }
    }
}

@Test
func nativeMembersWorkAcrossSwiftCallbackSuspension() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(
        modules: [CallbackAccess.self],
    )
    defer { await session.close() }
    let result = try await session.evaluate("""
    from callback_access import Counter, inspect, members, sum
    from datetime import datetime, UTC
    counter = Counter(7)
    date = datetime(2026, 11, 11, tzinfo=UTC)
    assert await inspect(date, counter) == [2026, 11, 8]
    assert counter.value == 8
    assert sum(20, 22) == 42
    assert await members(date, counter) == [2026, 11, 9, 29]
    """)
    #expect(result.end == .finished)
}

@Test(.timeLimit(.minutes(1)))
func inheritedCallbackAccessExpiresWhenItsExportReturns() async throws {
    let capture = EscapedCallback()
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [CallbackAccess.self])
    defer { await session.close() }
    let result = try await session.evaluate("""
    from callback_access import escape, expired
    from datetime import datetime
    await escape(datetime(2026, 11, 11))
    assert await expired()
    """, scope: capture)
    #expect(result.end == .finished)
}

@Test(.timeLimit(.minutes(1)))
func synchronousCallbacksCannotInheritAnotherSessionsExport() async throws {
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(modules: [CallbackAccess.self])
    let second = try await runtime.session(modules: [CallbackAccess.self])
    defer {
        await first.close()
        await second.close()
    }
    let result = try await first.evaluate(
        "from callback_access import nested; assert await nested()",
        scope: EscapedCallback(session: second),
    )
    #expect(result.end == .finished)
}

@Test
func nativeCallbackMutationsRemainAfterFailure() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [CallbackAccess.self])
    defer { await session.close() }
    _ = try await session.evaluate("""
    from callback_access import Counter, inspect
    from datetime import datetime, UTC
    counter = Counter(7)
    date = datetime(2026, 11, 11, tzinfo=UTC)
    """)
    await #expect(throws: Python::ExecutionError.self) {
        try await session.evaluate("""
        assert await inspect(date, counter) == [2026, 11, 8]
        raise ValueError("state remains")
        """)
    }
    let result = try await session.evaluate("""
    assert counter.value == 8
    assert await inspect(date, counter) == [2026, 11, 9]
    """)
    #expect(result.end == .finished)
}

// MARK: - CallbackAccessDelegate

private actor CallbackAccessDelegate: Python::Session.Delegate {
    private let allowed: Bool

    private(set) var requests: [Python::Session.FileAccessRequest] = []

    init(allowed: Bool) {
        self.allowed = allowed
    }

    func shouldAllowFileAccess(_ request: Python::Session.FileAccessRequest) async throws -> Bool {
        await Task.yield()
        requests.append(request)
        return allowed
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func nativeCallbackAccessUsesTheFileDelegate(allowed: Bool) async throws {
    try await withTemporaryDirectory { directory in
        let file = directory.appending("callback.txt")
        try await "callback contents".write(toFileAt: file)
        let delegate = CallbackAccessDelegate(allowed: allowed)
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(modules: [CallbackAccess.self], delegate: delegate)
        defer { await session.close() }
        try await session.set(file.string, forKey: "filename")
        try await session.set(allowed ? "callback contents" : "denied", forKey: "expected")
        let result = try await session.evaluate("""
        import asyncio
        from callback_access import read_text
        from pathlib import Path
        limit = asyncio.Semaphore(3)
        async def read_one():
            async with limit:
                try:
                    return await read_text(Path(filename))
                except PermissionError:
                    return "denied"
        values = await asyncio.gather(*(read_one() for _ in range(128)))
        assert values == [expected] * 128
        """, scope: "foreign callback")
        #expect(result.end == .finished)
        let requests = await delegate.requests
        #expect(requests.contains { $0.path == file && $0.scope as? String == "foreign callback" })
        #expect(requests.filter { $0.path == file }.count == 128)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func interruptionReachesEveryAttachedThread(timeout: Bool) async throws {
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(2))
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [CallbackAccess.self])
    defer { await session.close() }
    try await session.initialize()
    let evaluation = Task {
        defer { signal.continuation.finish() }
        return try await session.evaluate("""
        import asyncio
        from callback_access import spin, started
        class Runner:
            def spin(self):
                started()
                while True:
                    pass
        await asyncio.gather(spin(Runner()), spin(Runner()))
        """, scope: signal.continuation, timeout: timeout ? .seconds(2) : nil)
    }
    var readiness = signal.stream.makeAsyncIterator()
    #expect(await readiness.next() != nil)
    #expect(await readiness.next() != nil)
    if !timeout {
        evaluation.cancel()
    }
    let interrupted = try await evaluation.value
    #expect(interrupted.end == (timeout ? .timedOut : .stopped))
    let next = try await session.evaluate("assert 'Runner' in globals()")
    #expect(next.end == .finished)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func synchronousSwiftExportsUseTaskCancellation(timeout: Bool) async throws {
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [CallbackAccess.self])
    defer { await session.close() }
    try await session.initialize()

    let evaluation = Task {
        defer { signal.continuation.finish() }
        return try await session.evaluate(
            "from callback_access import spin_swift; spin_swift()",
            scope: signal.continuation,
            timeout: timeout ? .seconds(2) : nil,
        )
    }
    defer { evaluation.cancel() }

    _ = try await #require(nextSignal(from: signal.stream))
    if !timeout {
        evaluation.cancel()
    }
    let result = try await evaluation.value
    #expect(result.end == (timeout ? .timedOut : .stopped))
    #expect(try await session.evaluate("6 * 7").output.stdout == "42\n")
}

@Test
func nativeCallbackRejectsReferencesFromAnExpiredGeneration() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [CallbackAccess.self])
    defer { await session.close() }
    _ = try await session.evaluate("from datetime import datetime; date = datetime(2026, 11, 11)")
    let date = try await session.get("date", as: Python::DateTime.self)
    _ = try await session.evaluate(
        "from callback_access import saved_year; assert await saved_year() == 2026",
        scope: date,
    )
    try await session.reset()
    let result = try await session.evaluate("""
    from callback_access import saved_year
    try:
        await saved_year()
    except ReferenceError:
        pass
    else:
        raise AssertionError("An expired reference was accepted")
    """, scope: date)
    #expect(result.end == .finished)
    await session.close()
    #expect(throws: Python::Session.Error.self) { try date.year }
}

@Test
func nativeCallbackStreamsCloseEvenWhenItsContextIsRetained() async throws {
    try await withTemporaryDirectory { directory in
        let output = directory.appending("stdout.txt")
        let capture = RetainedCallback()
        let runtime = try await Python::Runtime()
        let session = try await runtime.session(modules: [CallbackAccess.self])
        defer { await session.close() }
        _ = try await session.evaluate("""
        import sys
        from callback_access import hold, spin
        class Writer:
            def spin(self):
                print("native output")
        await hold(sys.stdout.fileno())
        await spin(Writer())
        """, scope: capture, redirecting: [.stdout: output])
        let retained = try #require(capture.state.withLock { $0 })
        #expect(retained.0.scope == nil)

        let descriptor = FileDescriptor(rawValue: Int32(retained.1))
        let outputInfo = try output.stat()
        do {
            // Parallel tests can reuse a closed descriptor number for a different file.
            let current = try descriptor.stat()
            #expect(current.deviceID != outputInfo.deviceID || current.inode != outputInfo.inode)
        } catch let error as Errno {
            #expect(error == .badFileDescriptor)
        }

        let bytes = try await FileSystem.shared.withFileHandle(forReadingAt: output) {
            try await $0.readChunk(fromAbsoluteOffset: 0, length: .bytes(1024))
        }
        #expect(Array(bytes.readableBytesView) == Array("native output\n".utf8))
    }
}

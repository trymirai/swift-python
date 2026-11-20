//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing
#if canImport(Darwin)
private import Darwin
#elseif canImport(Glibc)
private import Glibc
#elseif canImport(Musl)
private import Musl
#endif

// MARK: - ContextCallHost

@PythonExportedModule("call_host")
private enum ContextCallHost {
    @PythonFunction
    static func scope(_ context: Python::Context) throws -> Int {
        guard let value = context.scope as? Int else {
            throw Python::Failure(.runtimeError, message: "Missing scope")
        }
        return value
    }

    @PythonFunction
    static func invoke(
        _ context: Python::Context,
        _ function: Python::Reference,
        _ value: Int,
    ) async throws -> Int {
        try await context.call(function, arguments: [value])
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["sync", "async_call", "awaitable", "instance", "method"])
func sessionCallsAcceptPythonCallables(_ name: String) async throws {
    let session = try await Python::Runtime().session(.source(contextCallSource), history: .init())
    defer { await session.close() }

    let value = try await callPythonFunction(
        name,
        in: session,
        arguments: [40],
        keywords: [("delta", 2)],
        as: Int.self,
    )
    #expect(value == 42)
    #expect(try await session.evaluate("42").number == 1)
}

@Test(.timeLimit(.minutes(1)))
func topLevelCallsShareTheirLoopAndIsolateLateCallbacks() async throws {
    let session = try await Python::Runtime().session(modules: [ContextCallHost.self])
    defer { await session.close() }

    _ = try await session.evaluate("""
    import asyncio, call_host, sys
    async def work():
        global previous, gate, finished
        previous = asyncio.get_running_loop()
        gate = previous.create_future()
        finished = previous.create_future()
        def late():
            print("late output")
            sys.stderr.buffer.write(b"late bytes")
            try:
                call_host.scope()
            except RuntimeError:
                finished.set_result("expired")
            else:
                finished.set_result("leaked")
        gate.add_done_callback(lambda _: previous.call_later(0, late))
        return 42
    """)
    #expect(try await callPythonFunction("work", in: session, as: Int.self) == 42)

    let next = try await session.evaluate("""
    assert previous is asyncio.get_running_loop()
    gate.set_result(None)
    assert await finished == "expired"
    print(call_host.scope())
    """, scope: 21)
    #expect(next.output.stdout == "21\n")
    #expect(next.output.stderr.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func cancellingAnEvaluationOnlyCancelsItsOwnPythonTasks() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }

    _ = try await session.evaluate("""
    import asyncio
    gate = asyncio.get_running_loop().create_future()
    async def read_gate():
        return await gate
    previous = asyncio.create_task(read_gate())
    await asyncio.sleep(0)
    """)
    let stopped = try await runUntilInterrupted(
        """
        current = asyncio.create_task(asyncio.sleep(60))
        await asyncio.sleep(0)
        print("ready")
        await asyncio.sleep(60)
        """,
        in: session,
        afterOutput: "ready",
    )
    #expect(stopped.end == .stopped)

    _ = try await session.evaluate("""
    assert current.cancelled()
    gate.set_result(42)
    assert await previous == 42
    """)
}

@Test(.timeLimit(.minutes(1)))
func asyncContextCallsKeepConcurrentRequestsAndScopesSeparate() async throws {
    let session = try await Python::Runtime().session(
        .source(contextCallSource),
        modules: [ContextCallHost.self],
    )
    defer { await session.close() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for value in 0 ..< 16 {
            group.addTask {
                let function = try await session.get("nested", as: Python::Reference.self)
                let result: Int = try await session.call(function, arguments: [value], scope: value)
                #expect(result == value * 2 + 2)
            }
        }
        try await group.waitForAll()
    }
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func asyncContextCallSuspendsTheSwiftCaller() async throws {
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (released, gate) = AsyncStream<Void>.makeStream()
    defer {
        signal.finish()
        gate.finish()
    }
    let host = Python::Module(
        "suspension_host",
        functions: [
            .init("pause") { _ in
                signal.finish()
                for await _ in released {}
                try Task.checkCancellation()
                return .none
            },
        ],
    )
    let session = try await Python::Runtime().session(
        .source("""
        import suspension_host
        async def run():
            await suspension_host.pause()
            return 42
        """),
        moduleDefinitions: [host],
    )
    defer { await session.close() }
    let pending = Task { @MainActor in
        try await callPythonFunction("run", in: session, as: Int.self)
    }
    defer { pending.cancel() }
    for await _ in entered {}
    MainActor.preconditionIsolated()
    gate.finish()
    #expect(try await pending.value == 42)
}

@Test(
    .timeLimit(.minutes(1)),
    arguments: [
        ("wait", 128),
        ("wait_child", 64),
        ("wait_group", 64),
        ("wait_detached", 64),
        ("wait_shielded", 64),
        ("busy", 1),
        ("busy_async", 1),
        ("busy_callback", 1),
    ],
)
func asyncContextCallCancellationJoinsPythonAndSwift(
    _ name: String,
    repetitions: Int,
) async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { entered.continuation.finish() }
    let cancelled = Mutex(0)
    let host = Python::Module(
        "wait_host",
        functions: [
            .init(
                "entered",
                synchronous: { _ in
                    entered.continuation.yield(())
                    return .none
                },
            ),
            .init("wait") { _ in
                defer {
                    if Task.isCancelled {
                        cancelled.withLock { $0 += 1 }
                    }
                }
                entered.continuation.yield(())
                try await Task.sleep(for: .seconds(60))
                return .none
            },
        ],
    )
    let session = try await Python::Runtime().session(
        .source(cancellationSource),
        moduleDefinitions: [host],
    )
    defer { await session.close() }

    let function = try await session.get(name, as: Python::Reference.self)
    var signals = entered.stream.makeAsyncIterator()
    for iteration in 1 ... repetitions {
        let pending = Task { try await session.call(function, as: Int.self) }
        defer { pending.cancel() }
        _ = try #require(await signals.next())
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }

        let cleaned = try await session.get("cleaned", as: Int.self)
        try #require(cleaned == iteration)
        if name.hasPrefix("wait") {
            let finishedCallbacks = cancelled.withLock { $0 }
            try #require(finishedCallbacks == iteration)
        }
    }
    #expect(try await session.evaluate("42").output.stdout == "42\n")
}

@Test(.timeLimit(.minutes(1)))
func asyncContextCallsPreserveResetBetweenQueueTurns() async throws {
    let (started, signal) = AsyncStream<Void>.makeStream()
    let (resume, gate) = AsyncStream<Void>.makeStream()
    let session = try await Python::Runtime().session(.source(contextCallSource))
    defer {
        signal.finish()
        gate.finish()
        await session.close()
    }
    let pending = Task {
        let function = try await session.get("async_call", as: Python::Reference.self)
        #expect(try await session.call(function, arguments: [40], as: Int.self) == 42)
        signal.finish()
        for await _ in resume {}
        return try await session.call(function, arguments: [40], as: Int.self)
    }
    defer { pending.cancel() }
    for await _ in started {}
    try await session.reset()
    gate.finish()
    try await expectPythonFailure(.exception(.referenceError)) { _ = try await pending.value }
    #expect(try await session.evaluate("42").output.stdout == "42\n")
}

@Test(.timeLimit(.minutes(1)), arguments: ["fail_sync", "fail_async"])
func sessionCallsPreservePythonExceptionTypes(_ name: String) async throws {
    let session = try await Python::Runtime().session(.source(contextCallSource))
    defer { await session.close() }
    let error = try await expectPythonFailure(.exception(.init(rawValue: "CallError"))) {
        _ = try await callPythonFunction(name, in: session, as: Int.self)
    }
    #expect(error.message == "from call")
}

@Test
func sessionCallsDecodeOwnedResults() async throws {
    let session = try await Python::Runtime().session(.source(contextCallSource))
    defer { await session.close() }
    await #expect(throws: Python::Failure.self) {
        try await callPythonFunction("sync", in: session, arguments: [40], as: String.self)
    }
    let result = try await callPythonFunction(
        "async_call",
        in: session,
        arguments: [40],
        as: ContextCallOwnedResult.self,
    )
    #expect(result.value == 42)
}

@Test(.timeLimit(.minutes(1)))
func asyncContextCallsCancelBeforeSubmissionAndRejectForeignReferences() async throws {
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(.source(contextCallSource))
    let second = try await runtime.session(.source(contextCallSource))
    defer {
        await first.close()
        await second.close()
    }
    let foreign = try await second.get("sync", as: Python::Reference.self)
    try await expectPythonFailure(.exception(.referenceError)) {
        _ = try await first.call(foreign, arguments: [40], as: Int.self)
    }

    let function = try await first.get("async_call", as: Python::Reference.self)
    let pending = Task {
        unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() }
        return try await first.call(function, arguments: [40], as: Int.self)
    }
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await first.call(function, arguments: [40], as: Int.self) == 42)
}

#if os(macOS) || os(Linux) || targetEnvironment(macCatalyst)
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func asyncContextCallsJoinSubprocessCleanup(_ fail: Bool) async throws {
    let runtime = try await Python::Runtime(options: [.subprocesses])
    let session = try await runtime.session(.source("""
    import subprocess
    def run(fail):
        global child, child_pid
        child = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        child_pid = child.pid
        if fail:
            raise ValueError("failed with a child")
        return 42
    """))
    defer { await session.close() }
    let error = try await #require(throws: (any Swift::Error).self) {
        try await callPythonFunction("run", in: session, arguments: [fail], as: Int.self)
    }
    if fail {
        #expect((error as? Python::Failure)?.kind == .exception(.valueError))
    } else {
        #expect(String(describing: error).contains("open PIPE"))
    }
    let pid = try await session.get("child_pid", as: Int32.self)
    let status = kill(pid, 0)
    let failure = errno
    #expect(status == -1)
    #expect(failure == ESRCH)
}
#endif

// MARK: - ContextCallOwnedResult

private struct ContextCallOwnedResult: ~Copyable, Python::Decodable, Sendable {
    let value: Int

    init(from decoder: borrowing Python::Decoder) throws {
        value = try decoder.object().decode(as: Int.self)
    }
}

func callPythonFunction<Result: Python::Decodable & Sendable & ~Copyable>(
    _ name: String,
    in session: Python::Session,
    arguments: [any Python::Encodable & Sendable] = [],
    keywords: [(String, any Python::Encodable & Sendable)] = [],
    as type: Result.Type,
) async throws -> Result {
    let function = try await session.get(name, as: Python::Reference.self)
    return try await session.call(function, arguments: arguments, keywords: keywords, as: type)
}

private let cancellationSource = """
import asyncio, wait_host

cleaned = 0

async def wait():
    global cleaned
    try:
        await wait_host.wait()
        return 42
    finally:
        await asyncio.sleep(0)
        cleaned += 1

async def wait_child():
    return await asyncio.create_task(wait())

async def wait_group():
    async with asyncio.TaskGroup() as group:
        group.create_task(wait())

async def wait_detached():
    child = asyncio.create_task(wait_group())
    await asyncio.Future()

async def wait_shielded():
    child = asyncio.create_task(wait())
    return await asyncio.shield(child)

def spin():
    wait_host.entered()
    while True:
        pass

def busy():
    global cleaned
    try:
        spin()
    finally:
        cleaned += 1

async def busy_async():
    global cleaned
    try:
        spin()
    finally:
        await asyncio.sleep(0)
        cleaned += 1

async def busy_callback():
    global cleaned
    loop = asyncio.get_running_loop()
    loop.call_soon(spin)
    try:
        await loop.create_future()
    finally:
        await asyncio.sleep(0)
        cleaned += 1
"""

private let contextCallSource = """
import asyncio

def sync(value, *, delta=2):
    return value + delta

async def async_call(value, *, delta=2):
    await asyncio.sleep(0)
    return value + delta

class Awaitable:
    def __init__(self, value):
        self.value = value
    def __await__(self):
        async def resolve():
            await asyncio.sleep(0)
            return self.value
        return resolve().__await__()

def awaitable(value, *, delta=2):
    return Awaitable(value + delta)

class Callable:
    async def __call__(self, value, *, delta=2):
        return await async_call(value, delta=delta)

instance = Callable()
method = instance.__call__

async def nested(value):
    import call_host
    return await call_host.invoke(async_call, value) + call_host.scope()

class CallError(ValueError):
    pass

def fail_sync():
    raise CallError("from call")

async def fail_async():
    await asyncio.sleep(0)
    fail_sync()
"""

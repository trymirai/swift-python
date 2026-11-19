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
            throw Python::Exception(name: "RuntimeError", message: "Missing scope")
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
func asyncContextCallsAcceptPythonCallables(_ name: String) async throws {
    let session = try await Python::Runtime().session(.source(contextCallSource), history: .init())
    defer { await session.close() }
    let value: Int = try await session.enqueue { context in
        let function = try await context.get(name, as: Python::Reference.self)
        return try await context.call(function, arguments: [40], keywords: [("delta", 2)])
    }
    #expect(value == 42)
    #expect(try await session.evaluate("42").number == 1)
}

@Test(.timeLimit(.minutes(1)))
func asyncContextCallsInheritScopeAndNestedCallbacks() async throws {
    let session = try await Python::Runtime().session(
        .source(contextCallSource),
        modules: [ContextCallHost.self],
    )
    defer { await session.close() }
    let value: Int = try await session.enqueue(scope: 20) { context in
        #expect(context.scope as? Int == 20)
        try await context.set(1, forKey: "marker")
        #expect(try await context.get("marker", as: Int.self) == 1)
        let function = try await context.get("nested", as: Python::Reference.self)
        let first: Int = try await context.call(function, arguments: [20])
        try await context.remove("marker")
        return try await context.call(function, arguments: [first])
    }
    #expect(value == 64)
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
                let result: Int = try await session.enqueue(scope: value) { context in
                    let function = try await context.get("nested", as: Python::Reference.self)
                    return try await context.call(function, arguments: [value])
                }
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
    let host = Python::Module("suspension_host", functions: [
        .init("pause") { _ in
            signal.finish()
            for await _ in released {}
            try Task.checkCancellation()
            return .none
        },
    ])
    let session = try await Python::Runtime().session(.source("""
    import suspension_host
    async def run():
        await suspension_host.pause()
        return 42
    """), moduleDefinitions: [host])
    defer { await session.close() }
    let pending = Task { @MainActor in
        try await session.enqueue { context in
            let function = try await context.get("run", as: Python::Reference.self)
            return try await context.call(function, as: Int.self)
        }
    }
    defer { pending.cancel() }
    for await _ in entered {}
    MainActor.preconditionIsolated()
    gate.finish()
    #expect(try await pending.value == 42)
}

@Test(.timeLimit(.minutes(1)), arguments: ["wait", "busy"])
func asyncContextCallCancellationJoinsPythonAndSwift(_ name: String) async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let suspended = AsyncStream<Void>.makeStream()
    let cancelled = Mutex(false)
    defer {
        entered.continuation.finish()
        suspended.continuation.finish()
    }
    let host = Python::Module("wait_host", functions: [
        .init("entered", synchronous: { _ in
            entered.continuation.yield(())
            return .none
        }),
        .init("wait") { _ in
            entered.continuation.yield(())
            defer { cancelled.withLock { $0 = Task.isCancelled } }
            for await _ in suspended.stream {}
            try Task.checkCancellation()
            return .none
        },
    ])
    let session = try await Python::Runtime().session(.source("""
    import wait_host
    cleaned = False
    async def wait():
        global cleaned
        try:
            await wait_host.wait()
            return 42
        finally:
            cleaned = True
    def busy():
        global cleaned
        try:
            wait_host.entered()
            while True:
                pass
        finally:
            cleaned = True
    """), moduleDefinitions: [host])
    defer { await session.close() }
    let pending = Task {
        try await session.enqueue { context in
            let function = try await context.get(name, as: Python::Reference.self)
            return try await context.call(function, as: Int.self)
        }
    }
    defer { pending.cancel() }
    _ = try await #require(nextSignal(from: entered.stream))
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(cancelled.withLock { $0 } == (name == "wait"))
    #expect(try await session.get("cleaned", as: Bool.self))
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
        try await session.enqueue { context in
            let function = try await context.get("async_call", as: Python::Reference.self)
            #expect(try await context.call(function, arguments: [40], as: Int.self) == 42)
            signal.finish()
            for await _ in resume {}
            return try await context.call(function, arguments: [40], as: Int.self)
        }
    }
    defer { pending.cancel() }
    for await _ in started {}
    try await session.reset()
    gate.finish()
    let error = try await #require(throws: Python::Exception.self) { try await pending.value }
    #expect(error.name == "ReferenceError")
    #expect(try await session.evaluate("42").output.stdout == "42\n")
}

@Test(.timeLimit(.minutes(1)), arguments: ["fail_sync", "fail_async"])
func asyncContextCallsPreserveErrorsAndOwnedResults(_ name: String) async throws {
    let session = try await Python::Runtime().session(.source(contextCallSource))
    defer { await session.close() }
    let error = try await #require(throws: Python::Exception.self) {
        try await session.enqueue { context in
            let function = try await context.get(name, as: Python::Reference.self)
            return try await context.call(function, as: Int.self)
        }
    }
    #expect(error.name == "ValueError")
    #expect(error.message == "from call")
    await #expect(throws: Python::Exception.self) {
        try await session.enqueue { context in
            let function = try await context.get("sync", as: Python::Reference.self)
            return try await context.call(function, arguments: [40], as: String.self)
        }
    }
    let result = try await session.enqueue { context in
        let function = try await context.get("async_call", as: Python::Reference.self)
        return try await context.call(function, arguments: [40], as: ContextCallOwnedResult.self)
    }
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
    let context = try await first.enqueue { context in
        await Task.yield()
        return context
    }
    let foreign = try await second.get("sync", as: Python::Reference.self)
    let error = try await #require(throws: Python::Exception.self) {
        try await context.call(foreign, arguments: [40], as: Int.self)
    }
    #expect(error.name == "ReferenceError")
    let function = try await context.get("async_call", as: Python::Reference.self)
    let pending = Task {
        unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() }
        return try await context.call(function, arguments: [40], as: Int.self)
    }
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await context.call(function, arguments: [40], as: Int.self) == 42)
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
        try await session.enqueue { context in
            let function = try await context.get("run", as: Python::Reference.self)
            return try await context.call(function, arguments: [fail], as: Int.self)
        }
    }
    if fail {
        #expect((error as? Python::Exception)?.name == "ValueError")
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

def fail_sync():
    raise ValueError("from call")

async def fail_async():
    await asyncio.sleep(0)
    fail_sync()
"""

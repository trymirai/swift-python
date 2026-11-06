//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - ValueModule

@PythonModule("host")
private enum ValueModule {
    @PythonFunction
    static func echo(_ value: Python::Value) -> Python::Value {
        value
    }

    @PythonFunction
    static func asyncEcho(_ value: Python::Value) async -> Python::Value {
        await Task.yield()
        return value
    }
}

@Test
func exportedValueConversions() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [ValueModule.self])
    _ = try await session.evaluate(#"""
    import host

    values = [None, True, False, -2**63, 2**63 - 1, 1.25, float('inf'),
              "hello\x00Привет 🐍", b"", bytes(range(256)) * 256,
              [1, {"text": "a\x00b", "bytes": b"\x00\xff"}]]
    for value in values:
        assert host.echo(value) == value
        assert await host.asyncEcho(value) == value
    assert host.echo((1, "two")) == [1, "two"]

    recursive = []
    recursive.append(recursive)
    for value in (2**63, {1: "invalid key"}, object(), recursive):
        try:
            host.echo(value)
        except (RuntimeError, TypeError, ValueError, OverflowError):
            pass
        else:
            raise AssertionError("Expected a conversion failure")
    assert host.echo("still attached") == "still attached"
    """#)
    await session.close()
}

@Test(.timeLimit(.minutes(1)))
func literalCallbackDefaults() async throws {
    let parameters: [Python::Module.Function.Parameter] = [
        .init("required"),
        .init("value", default: Python::Value.none),
        .init("suffix", default: .string("default")),
    ]
    let module = Python::Module("host", functions: [
        .init("sync", parameters: parameters, synchronous: { .list($0) }),
        .init("async_call", parameters: parameters, body: { .list($0) }),
    ])
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [module])
    _ = try await session.evaluate("""
    import host, inspect

    assert host.sync(1) == [1, None, "default"]
    assert await host.async_call(1) == [1, None, "default"]
    assert host.sync(1, suffix=None) == [1, None, None]
    assert await host.async_call(1, value=42) == [1, 42, "default"]
    for function in (host.sync, host.async_call):
        parameters = inspect.signature(function).parameters
        assert parameters["required"].default is inspect.Parameter.empty
        assert parameters["value"].default is None
        assert parameters["suffix"].default == "default"
        try:
            function()
        except TypeError:
            pass
        else:
            raise AssertionError("Expected a missing argument error")
    """)
    await session.close()
}

// MARK: - CallbackArguments

private enum CallbackArguments: CaseIterable {
    case values
    case scoped
}

@Test(.timeLimit(.minutes(1)), arguments: CallbackArguments.allCases)
private func stoppingEvaluationCancelsTheSwiftCallback(_ arguments: CallbackArguments) async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let suspended = AsyncStream<Void>.makeStream()
    let target = Mutex<Python::Session?>(nil)
    defer {
        entered.continuation.finish()
        completed.continuation.finish()
        suspended.continuation.finish()
        target.withLock { $0 = nil }
    }

    let wait: @Sendable () async throws -> Python::Value = {
        entered.continuation.yield(())
        for await _ in suspended.stream {}
        completed.continuation.yield(())
        try Task.checkCancellation()
        return .none
    }
    let function: Python::Module.Function = switch arguments {
    case .values:
        .init("wait") { _ in try await wait() }
    case .scoped:
        .init("wait", start: { _, _ in
            // Stop before Python can install its callback cleanup handler.
            let session = try #require(target.withLock { $0 })
            #expect(session.stop())
            return Python::Module.Function.makeOperation(wait)
        })
    }

    let host = Python::Module("host", functions: [function])
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [host])
    target.withLock { $0 = session }

    let evaluation = Task {
        try await session.evaluate("""
        import asyncio, host

        callback_errors = []
        asyncio.get_running_loop().set_exception_handler(
            lambda loop, context: callback_errors.append(context["message"])
        )
        await host.wait()
        """)
    }
    defer { evaluation.cancel() }
    var starts = entered.stream.makeAsyncIterator()
    let started: Void? = await starts.next()
    try #require(started != nil)
    if arguments == .values {
        #expect(session.stop())
    }

    let error = try await #require(throws: Python::ExecutionError.self) {
        try await evaluation.value
    }
    guard case .stopped = error else {
        throw error
    }

    var completions = completed.stream.makeAsyncIterator()
    let finished: Void? = await completions.next()
    try #require(finished != nil)

    let output = try await session.evaluate("""
    assert not callback_errors, callback_errors
    42
    """)
    #expect(output.stdout == "42\n")
    await session.close()
}

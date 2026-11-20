//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - ValueModule

@PythonExportedModule("host")
private enum ValueModule {
    @PythonFunction
    static func echo(_ value: Python::Value) -> Python::Value {
        value
    }

    @MainActor
    @PythonFunction
    static func asyncEcho(_ value: Python::Value) async -> Python::Value {
        await Task.yield()
        MainActor.preconditionIsolated()
        return value
    }
}

@Test
func exportedValueConversions() async throws {
    try await evaluateInFreshSession(
        #"""
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
        """#,
        modules: [ValueModule.self],
    )
}

@Test(.timeLimit(.minutes(1)))
func literalCallbackDefaults() async throws {
    let parameters: [Python::Module.Function.Parameter] = [
        .init("required"),
        .init("value", default: Python::Value.none),
        .init("suffix", default: .string("default")),
    ]
    let module = Python::Module(
        "host",
        functions: [
            .init("sync", parameters: parameters, synchronous: { .list($0) }),
            .init("async_call", parameters: parameters, body: { .list($0) }),
        ],
    )
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [module])
    defer { await session.close() }

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
}

// MARK: - CallbackInterruption

private enum CallbackInterruption: CaseIterable {
    case cancelBeforeSubmission
    case cancelTask

    func makeWaitFunction(
        _ wait: @escaping @Sendable () async throws -> Python::Value,
    ) -> Python::Module.Function {
        guard self == .cancelBeforeSubmission else {
            return .init("wait") { _ in try await wait() }
        }
        return .init(
            "wait",
            start: { _, _ in
                unsafe withUnsafeCurrentTask { task in
                    unsafe task?.cancel()
                }
                return Python::Module.Function.makeOperation(wait)
            },
        )
    }
}

@Test(.timeLimit(.minutes(1)), arguments: CallbackInterruption.allCases)
private func interruptedEvaluationJoinsSwiftCallbacks(
    _ interruption: CallbackInterruption,
) async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let suspended = AsyncStream<Void>.makeStream()

    let lifecycle = Mutex((started: false, cancelled: false))
    defer {
        entered.continuation.finish()
        suspended.continuation.finish()
    }

    @Sendable
    func wait() async throws -> Python::Value {
        lifecycle.withLock { $0.started = true }
        entered.continuation.yield(())
        defer { lifecycle.withLock { $0.cancelled = Task.isCancelled } }

        for await _ in suspended.stream {}
        try Task.checkCancellation()
        return .none
    }

    let function = interruption.makeWaitFunction(wait)
    let host = Python::Module("host", functions: [function])
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [host])
    defer { await session.close() }

    try await session.initialize()

    @Sendable
    func evaluateWait() async throws -> Python::Execution {
        try await session.evaluate("""
        import asyncio, host

        callback_errors = []
        asyncio.get_running_loop().set_exception_handler(
            lambda loop, context: callback_errors.append(context["message"])
        )
        await host.wait()
        """)
    }

    let execution: Python::Execution
    switch interruption {
    case .cancelBeforeSubmission:
        let evaluation = Task { try await evaluateWait() }
        defer { evaluation.cancel() }
        execution = try await evaluation.value
    case .cancelTask:
        execution = try await runUntilInterrupted(whenReady: entered, evaluateWait)
    }
    #expect(execution.end == .stopped)

    let observation = lifecycle.withLock { $0 }
    let submitted = interruption != .cancelBeforeSubmission
    #expect(observation.started == submitted)
    #expect(observation.cancelled == submitted)

    let next = try await session.evaluate("""
    assert not callback_errors, callback_errors
    42
    """)
    #expect(next.output.stdout == "42\n")
}

@Test(.timeLimit(.minutes(1)))
func cancellingOnePythonAwaitCancelsOnlyItsSwiftCallback() async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let suspended = AsyncStream<Void>.makeStream()
    let cancelled = AsyncStream<Void>.makeStream()
    defer {
        entered.continuation.finish()
        suspended.continuation.finish()
        cancelled.continuation.finish()
    }

    let host = Python::Module(
        "host",
        functions: [
            .init("wait") { _ in
                entered.continuation.yield(())
                defer {
                    if Task.isCancelled {
                        cancelled.continuation.finish()
                    }
                }
                for await _ in suspended.stream {}
                try Task.checkCancellation()
                return .none
            },
            .init("started") { _ in
                _ = await nextSignal(from: entered.stream)
                return .none
            },
            .init("answer_after_cancel") { _ in
                for await _ in cancelled.stream {}
                try Task.checkCancellation()
                return .integer(42)
            },
        ],
    )
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [host])
    defer { await session.close() }

    _ = try await session.evaluate("""
    import asyncio, host
    waiting = asyncio.create_task(host.wait())
    await host.started()
    answer = asyncio.create_task(host.answer_after_cancel())
    waiting.cancel()
    try:
        await waiting
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("Expected the first callback to be cancelled")
    assert await answer == 42
    """)
}

@Test(.timeLimit(.minutes(1)))
func swiftCallbacksRunDuringInstallationEnqueueAndImportUpdates() async throws {
    let host = Python::Module(
        "host",
        source: """
        import asyncio
        import sys

        def read_answer():
            return asyncio.run(answer())

        startup_answer = read_answer()
        cached_answer = None

        class Finder:
            def find_spec(self, fullname, path=None, target=None):
                return None

            def invalidate_caches(self):
                global cached_answer
                cached_answer = read_answer()

        sys.meta_path.append(Finder())
        """,
        functions: [.init("answer", body: { _ in .integer(42) })],
    )
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [host])
    let value = try await session.enqueue { context in
        let host = try context.import(module: "host")
        let answer = try host(methodNamed: "read_answer")().decode(as: Int.self)
        return try host.value(forAttribute: "startup_answer").decode(as: Int.self) + answer
    }
    #expect(value == 84)
    try await session.replaceImportPaths([])
    _ = try await session.evaluate("import host; assert host.cached_answer == 42")
    await session.close()
}

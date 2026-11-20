//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

@Test(.timeLimit(.minutes(1)))
func callbackCannotAwaitItsOwnSession() async throws {
    let target = Mutex<Python::Session?>(nil)
    defer { target.withLock { $0 = nil } }

    @Sendable
    func callbackSession() throws -> Python::Session {
        try #require(target.withLock { $0 })
    }

    let functions: [Python::Module.Function] = [
        contextFunction(
            "read",
            operation: { context in
                try await callbackSession().get("value", as: Int.self, in: context)
            },
        ),
        contextFunction(
            "reset",
            operation: { context in
                try await callbackSession().reset(in: context)
                return Python::Value.none
            },
        ),
        contextFunction(
            "imports",
            operation: { context in
                try await callbackSession().replaceImportPaths([], in: context)
                return Python::Value.none
            },
        ),
        contextFunction(
            "evaluate",
            operation: { context in
                _ = try await callbackSession().evaluate("1", in: context)
                return Python::Value.none
            },
        ),
    ]

    let module = Python::Module("reentry", functions: functions)
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [module])
    defer { await session.close() }

    target.withLock { $0 = session }

    _ = try await session.evaluate("""
    import reentry
    value = 42
    for function in (reentry.read, reentry.reset, reentry.imports, reentry.evaluate):
        try:
            await function()
        except RuntimeError as error:
            assert 'session is busy' in str(error)
        else:
            raise AssertionError(f"Expected {function.__name__} to reject reentry")
    assert value == 42
    """)
    #expect(try await session.get("value", as: Int.self) == 42)
}

@Test(.timeLimit(.minutes(1)))
func callbackChainCannotAwaitAnAncestor() async throws {
    let targets = Mutex<(first: Python::Session, second: Python::Session)?>(nil)
    defer { targets.withLock { $0 = nil } }
    let forward = contextFunction("forward") { context in
        let second = try #require(targets.withLock { $0?.second })
        _ = try await second.evaluate("import chain; await chain.back()", in: context)
        return Python::Value.none
    }
    let back = contextFunction("back") { context in
        let first = try #require(targets.withLock { $0?.first })
        return try await first.get("value", as: Int.self, in: context)
    }
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(moduleDefinitions: [.init("chain", functions: [forward])])
    let second = try await runtime.session(moduleDefinitions: [.init("chain", functions: [back])])
    defer {
        await first.close()
        await second.close()
    }

    targets.withLock { $0 = (first, second) }
    _ = try await first.evaluate("""
    import chain
    value = 42
    try:
        await chain.forward()
    except RuntimeError as error:
        assert 'session is busy' in str(error)
    else:
        raise AssertionError("Expected the callback to reject reentry into its ancestor")
    """)
    #expect(try await first.get("value", as: Int.self) == 42)
}

@Test(.timeLimit(.minutes(1)))
func callbackDoesNotWaitForAnotherBusySession() async throws {
    let (entered, ready) = AsyncStream<Void>.makeStream()
    let (waiting, release) = AsyncStream<Void>.makeStream()

    let hold = Python::Module.Function("hold") { _ in
        ready.finish()
        for await _ in waiting {}
        return .none
    }
    let runtime = try await Python::Runtime()
    let target = try await runtime.session(moduleDefinitions: [.init("blocked", functions: [hold])])
    try await target.set(42, forKey: "value")
    let read = contextFunction("read") { context in
        do {
            _ = try await target.get("value", as: Int.self, in: context)
            return false
        } catch let error as Python::Failure where error.kind == .busy {
            return true
        }
    }
    let caller = try await runtime.session(moduleDefinitions: [.init("probe", functions: [read])])
    defer {
        await caller.close()
        await target.close()
    }

    let active = Task { try await target.evaluate("import blocked; await blocked.hold()") }
    defer {
        release.finish()
        active.cancel()
    }

    for await _ in entered {}
    let queued = Task { try await target.get("value", as: Int.self) }
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }

    _ = try await caller.evaluate("import probe; was_busy = await probe.read()")
    let wasBusy = try await caller.get("was_busy", as: Bool.self)
    #expect(wasBusy)
    release.finish()
    _ = try await active.value
    #expect(try await target.get("value", as: Int.self) == 42)
}

private func contextFunction(
    _ name: String,
    operation: @escaping @Sendable (
        Python::Context,
    ) async throws -> any Python::Encodable & Sendable,
) -> Python::Module.Function {
    .init(
        name,
        start: { _, context in
            let context = context
            return { try await operation(context) }
        },
    )
}

@Test
func retainedCommitAndContextLoseTheirAuthority() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }

    let retained = Mutex<Python::Session.Commit?>(nil)
    _ = try await session.evaluate(
        "value = 42",
        committing: { commit in
            retained.withLock { $0 = commit }
        },
    )
    let commit = try #require(retained.withLock { $0 })
    try expectPythonFailure(.closed) { try commit.seal() }

    let expired = try await session.enqueue { $0 }
    await session.close(in: expired)
    #expect(try await session.get("value", as: Int.self) == 42)
}

@Test
func sessionCallsRequireAnActiveParentCallback() async throws {
    let runtime = try await Python::Runtime()
    let target = try await runtime.session(.source("def answer(): return 42"))
    defer { await target.close() }
    let function: Python::Reference = try await target.get("answer")
    let retained = Mutex<Python::Context?>(nil)
    let capture = contextFunction("capture") { parent in
        retained.withLock { $0 = parent }
        return try await target.call(function, as: Int.self, in: parent)
    }
    let bridge = Python::Module("bridge", functions: [capture])
    let origin = try await runtime.session(moduleDefinitions: [bridge])
    defer { await origin.close() }
    _ = try await origin.evaluate("import bridge; assert await bridge.capture() == 42")

    let expired = try #require(retained.withLock { $0 })
    try await expectPythonFailure(.closed) {
        _ = try await target.call(function, as: Int.self, in: expired)
    }
    try await expectPythonFailure(.closed) {
        _ = try await ReentryScope.read(in: target, from: expired)
    }
    await target.close()
    try await expectPythonFailure(.closed) {
        _ = try await target.call(function, as: Int.self)
    }
}

// MARK: - ReentryScope

@PythonImportedClass(module: "reentry_scope", name: "Probe")
private struct ReentryScope {
    @PythonFunction
    static func read() async throws -> String

    static var module: Python::Module {
        let reporter = contextFunction("report") { context in context.scope as? String ?? "unset" }
        return Python::Module(
            "reentry_scope",
            source: """
            class Probe:
                @staticmethod
                async def read():
                    return await report()
            """,
            functions: [reporter],
        )
    }
}

@Test(.timeLimit(.minutes(1)))
func typedCallsOnlyUseTheScopeSuppliedForTheirSession() async throws {
    let probe = ReentryScope.module
    let runtime = try await Python::Runtime()
    let target = try await runtime.session(moduleDefinitions: [probe])
    defer { await target.close() }

    let read = contextFunction("read") { parent in
        let local = try await ReentryScope.read()
        let host = try await ReentryScope.read(in: target)
        let remote = try await ReentryScope.read(in: target, from: parent)
        let scoped = try await ReentryScope.read(in: target, from: parent, scope: "target")
        return [local, host, remote, scoped]
    }
    let caller = try await runtime.session(moduleDefinitions: [
        probe,
        .init("bridge", functions: [read]),
    ])
    defer { await caller.close() }
    _ = try await caller.evaluate("import bridge; scopes = await bridge.read()", scope: "origin")
    let scopes: [String] = try await caller.get("scopes")
    #expect(scopes == ["origin", "unset", "unset", "target"])

    try await expectPythonFailure(.closed) { _ = try await ReentryScope.read() }
}

@Test(.timeLimit(.minutes(1)))
func anExplicitSessionCallSurvivesAnExpiredInheritedExport() async throws {
    let runtime = try await Python::Runtime()
    let target = try await runtime.session(moduleDefinitions: [ReentryScope.module])
    defer { await target.close() }

    let (release, gate) = AsyncStream<Void>.makeStream()
    let pending = Mutex<Task<String, any Swift::Error>?>(nil)
    let capture = contextFunction("capture") { _ in
        let task = Task {
            for await _ in release {}
            try await expectPythonFailure(.closed) { _ = try await ReentryScope.read() }
            return try await ReentryScope.read(in: target)
        }
        pending.withLock { $0 = task }
        return true
    }

    let origin = try await runtime.session(moduleDefinitions: [.init(
        "bridge",
        functions: [capture],
    )])
    defer {
        gate.finish()
        await origin.close()
    }
    _ = try await origin.evaluate("import bridge; assert await bridge.capture()")
    gate.finish()
    let task = try #require(pending.withLock { $0 })
    #expect(try await task.value == "unset")
}

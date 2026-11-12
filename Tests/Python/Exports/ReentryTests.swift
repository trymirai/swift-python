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
        contextFunction("read", operation: { context in
            try await callbackSession().get("value", as: Int.self, in: context)
        }),
        contextFunction("reset", operation: { context in
            try await callbackSession().reset(in: context)
            return Python::Value.none
        }),
        contextFunction("imports", operation: { context in
            try await callbackSession().replaceImportPaths([], in: context)
            return Python::Value.none
        }),
        contextFunction("evaluate", operation: { context in
            _ = try await callbackSession().evaluate("1", in: context)
            return Python::Value.none
        }),
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
        } catch Python::Session.Error.busy {
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
    .init(name, start: { _, context in
        let context = context
        return { try await operation(context) }
    })
}

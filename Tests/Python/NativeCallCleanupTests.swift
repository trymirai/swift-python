//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - NativeCleanupEvent

private enum NativeCleanupEvent: Equatable, Sendable {
    case entered
    case finished(cancelled: Bool)
    case returned
}

@Test(.timeLimit(.minutes(1)))
func returningFromPythonJoinsAnOutstandingSwiftCallback() async throws {
    let entered = AsyncStream<Void>.makeStream()
    defer { entered.continuation.finish() }
    let cancelled = Mutex(false)
    let host = Python::Module("host", functions: [
        .init("wait") { _ in
            entered.continuation.yield(())
            defer { cancelled.withLock { $0 = Task.isCancelled } }
            try await Task.sleep(for: .seconds(30))
            return .none
        },
        .init("started") { _ in
            _ = await nextSignal(from: entered.stream)
            return .none
        },
    ])
    let session = try await Python::Runtime().session(moduleDefinitions: [host])
    defer { await session.close() }

    _ = try await session.evaluate("""
    import asyncio, host
    pending = asyncio.create_task(host.wait())
    await host.started()
    """)
    #expect(cancelled.withLock { $0 })
    _ = try await session.evaluate("assert pending.cancelled()")
}

// MARK: - NativeCleanupOutcome

private enum NativeCleanupOutcome: CaseIterable, Sendable {
    case success
    case python
    case decode
    case cancel
}

@Test(.timeLimit(.minutes(1)), arguments: NativeCleanupOutcome.allCases)
private func asyncContextCallsJoinResourceCleanup(_ outcome: NativeCleanupOutcome) async throws {
    let events = AsyncStream<NativeCleanupEvent>.makeStream()
    let released = AsyncStream<Void>.makeStream()
    defer {
        events.continuation.finish()
        released.continuation.finish()
    }

    let host = Python::Module(
        "native_cleanup_host",
        functions: [
            .init("finish") { _ in
                events.continuation.yield(.entered)
                defer {
                    events.continuation.yield(.finished(cancelled: Task.isCancelled))
                }
                for await _ in released.stream {}
                try Task.checkCancellation()
                return .none
            },
        ],
    )
    let session = try await Python::Runtime().session(
        .source(cleanupSource),
        moduleDefinitions: [host],
    )
    defer { await session.close() }

    let pending = Task {
        defer {
            events.continuation.yield(.returned)
            events.continuation.finish()
        }
        if outcome == .decode {
            _ = try await callPythonFunction(
                "run",
                in: session,
                arguments: [false],
                as: String.self,
            )
            return 0
        }
        return try await callPythonFunction(
            "run",
            in: session,
            arguments: [outcome == .python],
            as: Int.self,
        )
    }
    defer { pending.cancel() }

    var iterator = events.stream.makeAsyncIterator()
    #expect(await iterator.next() == .entered)
    if outcome == .cancel {
        pending.cancel()
    } else {
        released.continuation.finish()
    }
    try await checkResult(of: pending, for: outcome)

    #expect(await iterator.next() == .finished(cancelled: outcome == .cancel))
    #expect(await iterator.next() == .returned)
    if outcome != .cancel {
        #expect(try await session.get("cleanup_finished", as: Bool.self))
    }
    #expect(try await session.evaluate("42").output.stdout == "42\n")
}

private func checkResult(
    of pending: Task<Int, any Swift::Error>,
    for outcome: NativeCleanupOutcome,
) async throws {
    switch outcome {
    case .cancel:
        await #expect(throws: CancellationError.self) { try await pending.value }
    case .success:
        #expect(try await pending.value == 42)
    case .python:
        let error = try await expectPythonFailure(.exception(.valueError)) {
            _ = try await pending.value
        }
        #expect(error.message == "delivered failure")
    case .decode:
        _ = try await #require(throws: Python::Failure.self) { try await pending.value }
    }
}

private let cleanupSource = """
import native_cleanup_host
from contextlib import aclosing

cleanup_finished = False

async def resource():
    global cleanup_finished
    try:
        yield 42
    finally:
        await native_cleanup_host.finish()
        cleanup_finished = True

async def run(fail):
    async with aclosing(resource()) as values:
        value = await anext(values)
        if fail:
            raise ValueError('delivered failure')
        return value
"""

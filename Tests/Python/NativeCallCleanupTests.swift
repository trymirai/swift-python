//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - NativeCleanupEvent

private enum NativeCleanupEvent: Sendable {
    case entered
    case returned
}

@Test(.timeLimit(.minutes(1)), arguments: ["success", "python", "decode", "cancel"])
func asyncContextCallsJoinCleanupAfterDeliveredResults(_ outcome: String) async throws {
    let events = AsyncStream<NativeCleanupEvent>.makeStream()
    let released = AsyncStream<Void>.makeStream()
    let cleanup = Mutex((finished: false, cancelled: false))
    defer {
        events.continuation.finish()
        released.continuation.finish()
    }
    let host = Python::Module("native_cleanup_host", functions: [
        .init("finish") { _ in
            events.continuation.yield(.entered)
            defer {
                cleanup.withLock { $0 = (true, Task.isCancelled) }
            }
            for await _ in released.stream {}
            try Task.checkCancellation()
            return .none
        },
    ])
    let session = try await Python::Runtime().session(.source("""
    import native_cleanup_host
    cleanup_finished = False
    async def resource():
        global cleanup_finished
        try:
            yield 42
        finally:
            await native_cleanup_host.finish()
            cleanup_finished = True
    async def run(fail):
        global pending_resource
        pending_resource = resource()
        value = await anext(pending_resource)
        if fail:
            raise ValueError('delivered failure')
        return value
    """), moduleDefinitions: [host])
    defer { await session.close() }
    let pending = Task {
        defer { events.continuation.yield(.returned) }
        return try await session.enqueue { context in
            let function = try await context.get("run", as: Python::Reference.self)
            if outcome == "decode" {
                _ = try await context.call(function, arguments: [false], as: String.self)
                return 0
            }
            return try await context.call(function, arguments: [outcome == "python"], as: Int.self)
        }
    }
    defer { pending.cancel() }
    var iterator = events.stream.makeAsyncIterator()
    #expect(await iterator.next() == .entered)
    if outcome == "cancel" {
        pending.cancel()
    }
    released.continuation.finish()
    if outcome == "cancel" {
        await #expect(throws: CancellationError.self) { try await pending.value }
    } else if outcome == "success" {
        #expect(try await pending.value == 42)
    } else {
        let error = try await #require(throws: Python::Exception.self) { try await pending.value }
        if outcome == "python" {
            #expect(error.name == "ValueError")
            #expect(error.message == "delivered failure")
        }
    }
    #expect(cleanup.withLock { $0.finished && $0.cancelled == (outcome == "cancel") })
    if outcome != "cancel" {
        #expect(try await session.get("cleanup_finished", as: Bool.self))
    }
    #expect(try await session.evaluate("42").output.stdout == "42\n")
}

//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - CounterModule

@PythonExportedModule("counter_base")
private enum CounterModule {}

// MARK: - LabeledCounterModule

@PythonExportedModule("counter_child")
private enum LabeledCounterModule {
    @PythonFunction
    static func echo(_ value: Counter) -> Counter {
        value
    }

    @PythonFunction
    static func echoList(_ values: [Counter]) -> [Counter] {
        values
    }
}

// MARK: - CounterLifetime

private enum CounterLifetime {
    static let instanceCount: Mutex = .init(0)
}

// MARK: - Counter

@PythonExportedClass("Counter", module: CounterModule.self)
private class Counter {
    private var secret = 0

    @PythonProperty
    var value: Int

    @PythonProperty("readOnlyValue", isReadOnly: true)
    var `default`: Int

    @PythonProperty
    var callback: Python::Reference?

    @PythonProperty
    var next: Counter?

    @PythonProperty
    private var cached: Counter?

    @PythonInit
    init(_ value: Int = 0, linkToSelf: Bool = false, in context: Python::Context) throws {
        CounterLifetime.instanceCount.withLock { $0 += 1 }
        try self.$value(value)
        try self.$default(7)

        if linkToSelf {
            try self.$next(self)
            // The construction scope keeps the self-linked wrapper alive during collection.
            _ = try context.import(module: "gc").attribute("collect").call()
        }

        guard value >= 0 else {
            throw Python::Exception(
                name: "ValueError",
                message: "negative",
            )
        }
    }

    deinit { CounterLifetime.instanceCount.withLock { $0 -= 1 } }

    @PythonFunction
    func increment(_ amount: Int = 1) throws -> Int {
        secret += 1
        try self.$value { $0 + amount }
        return try self.value
    }

    @PythonFunction
    func myself() -> Counter {
        self
    }

    @PythonFunction
    func describe() -> String {
        "base"
    }

    @PythonFunction
    func invoke(_ context: Python::Context) throws -> Int {
        guard let reference = try self.callback else {
            return -1
        }
        let function = try context.object(reference)
        return try function.call().decode()
    }

    @PythonFunction
    func cache(_ value: Counter) throws {
        try self.$cached(value)
    }

    @PythonFunction
    func recall() throws -> Counter? {
        try self.cached
    }
}

extension Counter {
    @PythonFunction
    func extended(_ amount: Int) throws -> Int {
        try value + amount
    }

    @PythonProperty
    var doubled: Int {
        get { secret * 2 }
        set { secret = newValue / 2 }
    }
}

// MARK: - LabeledCounter

@PythonExportedClass("Labeled", module: LabeledCounterModule.self)
private final class LabeledCounter: Counter {
    @PythonProperty
    let label: String

    @PythonInit
    init(_ value: Int, label: String = "label", in context: Python::Context) throws {
        self.label = label
        try super.init(value, in: context)
    }

    override func describe() -> String {
        "child:" + label
    }
}

// MARK: - ExistingInstance

@PythonExportedClass(module: LabeledCounterModule.self)
private final class ExistingInstance: Sendable {
    @PythonProperty
    var note: String?

    @PythonProperty
    let number = 42

    @PythonFunction
    func asynchronous(_ context: Python::Context) async -> Int {
        await Task.yield()
        return number + (context.scope as? Int ?? 0)
    }
}

@Test
func exportedClassInheritanceAndGarbageCollection() async throws {
    let runtime = try await Python::Runtime()
    // The base's module is pulled in by the exported Swift inheritance graph.
    let session = try await runtime.session(modules: [LabeledCounterModule.self])

    try await withSession(session) { session in
        try await checkInheritedClass(in: session)
        try await checkRejectedClassOperations(in: session)
        try await checkClassLifetimes(in: session)
    }
}

private func checkInheritedClass(in session: Python::Session) async throws {
    _ = try await session.evaluate("""
    from counter_base import Counter
    from counter_child import Labeled, echo, echoList, ExistingInstance
    import inspect, weakref, gc, typing

    x = Labeled(40, label='x')
    assert isinstance(x, Counter)
    assert x.value == 40 and x.label == 'x'
    assert x.increment(2) == 42
    assert x.extended(1) == 43
    assert x.describe() == 'child:x'
    assert x.myself() is x and echo(x) is x
    assert echoList([x, x]) == [x, x] and echoList([x])[0] is x
    x.doubled = 20
    assert x.doubled == 20
    x.value = 10
    x.__init__(999, label='changed')
    assert x.value == 10 and x.label == 'x'
    assert x.readOnlyValue == 7
    assert not hasattr(x, 'secret')
    assert list(inspect.signature(Counter.increment).parameters) == ['self', 'amount']
    assert inspect.signature(echo).return_annotation == 'counter_base.Counter'
    assert typing.get_type_hints(echo) == {'value': Counter, 'return': Counter}
    assert typing.get_type_hints(echoList)['return'] == list[Counter]
    assert typing.get_type_hints(Counter.recall)['return'] == Counter | None
    assert typing.get_type_hints(Counter.next.fget)['return'] == Counter | None
    assert Counter.next.__doc__.startswith('counter_base.Counter | None')


    linked = Counter(12, True)
    assert linked.value == 12 and linked.next is linked
    dead_linked = weakref.ref(linked)
    del linked
    gc.collect()
    assert dead_linked() is None
    """)
}

private func checkRejectedClassOperations(in session: Python::Session) async throws {
    _ = try await session.evaluate("""
    rejected = [
        (AttributeError, lambda: setattr(x, 'readOnlyValue', 8)),
        (AttributeError, lambda: setattr(x, 'other', 1)),
        (TypeError, lambda: setattr(Counter, 'extra', 1)),
        (TypeError, lambda: ExistingInstance()),
        (ValueError, lambda: Counter(-1, True)),
        (TypeError, lambda: Counter('bad')),
        (TypeError, lambda: x.increment(None)),
        (TypeError, lambda: echoList([object()])),
    ]
    for expected_error, action in rejected:
        try:
            action()
        except expected_error:
            pass
        else:
            raise AssertionError(f"Expected {expected_error.__name__}")

    try:
        class PythonChild(Counter):
            pass
    except TypeError:
        pass
    else:
        raise AssertionError("Expected Python subclasses of Counter to be rejected")
    """)
}

private func checkClassLifetimes(in session: Python::Session) async throws {
    _ = try await session.evaluate("""
    assert x.callback is None and x.invoke() == -1
    assert x.next is None and x.recall() is None
    x.next = x
    x.cache(x)
    x.callback = lambda captured=x: captured.value + 1
    assert x.next is x and x.recall() is x
    assert not hasattr(x, 'cached')
    assert x.invoke() == 11
    dead = weakref.ref(x)
    try:
        x.next = object()
    except TypeError:
        assert x.next is x
    else:
        raise AssertionError("Expected a Counter")
    """)
    try await checkManagedPythonCounter(in: session)
    _ = try await session.evaluate("gc.collect(); assert dead() is None")
    #expect(CounterLifetime.instanceCount.withLock { $0 } == 0)

    try await checkManagedSwiftCounter(in: session)
    _ = try await session.evaluate("gc.collect()")
    #expect(CounterLifetime.instanceCount.withLock { $0 } == 0)
}

private func checkManagedPythonCounter(in session: Python::Session) async throws {
    let managed = try await session.enqueue { context in
        try Python::Managed(context.get("x", as: Counter.self))
    }
    _ = try await session.evaluate("del x; gc.collect(); assert dead() is not None")

    let value = try await managed { counter in
        #expect(try counter.next === counter)
        try counter.$next(nil)
        #expect(try counter.next == nil)
        try counter.$next(counter)

        #expect(throws: CancellationError.self) {
            try counter.$value { _ in throw CancellationError() }
        }
        #expect(try counter.value == 10)
        return try counter.increment(2)
    }
    #expect(value == 12)
}

private func checkManagedSwiftCounter(in session: Python::Session) async throws {
    let managed = try await session.enqueue { context in
        let counter = try Counter(40, linkToSelf: true, in: context)
        #expect(try counter.value == 40)
        #expect(try counter.next === counter)
        return try Python::Managed(counter)
    }
    let value = try await managed { counter in
        #expect(try counter.next === counter)
        return try counter.increment(2)
    }
    #expect(value == 42)
}

@Test
func classIdentityAndSessionGenerations() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [LabeledCounterModule.self])
    let other = try await runtime.session(modules: [LabeledCounterModule.self])
    defer {
        await session.close()
        await other.close()
    }

    let peer = ExistingInstance()
    try await session.set(peer, forKey: "peer")
    let decoded = try await session.get("peer", as: ExistingInstance.self)
    #expect(decoded === peer)

    _ = try await session
        .evaluate("import weakref; dead_peer = weakref.ref(peer); peer.note = 'old'")
    try await session.remove("peer")
    _ = try await session.evaluate("import gc; gc.collect(); assert dead_peer() is None")

    // The Swift instance survives collection of the original Python wrapper.
    try await session.set(peer, forKey: "peer")
    _ = try await session.evaluate("assert peer.note is None and peer.number == 42")
    await #expect(throws: (any Swift::Error).self) { try await other.set(peer, forKey: "peer") }

    let managed = try await session.enqueue { _ in try Python::Managed(peer) }
    _ = try await session.evaluate("assert await peer.asynchronous() == 43", scope: 1)
    _ = try await session.evaluate("assert await peer.asynchronous() == 42")
    try await session.set(42, forKey: "value")
    let value: Int = try await managed { peer in
        await Task.yield()
        #expect(peer.number == 42)
        return try await session.get("value")
    }
    #expect(value == 42)

    try await session.reset()
    await #expect(throws: Python::Exception.self) { try await session.set(peer, forKey: "peer") }
    await #expect(throws: Python::Exception.self) { try await managed { $0.number } }
}

// MARK: - CheckpointModule

@PythonExportedModule("checkpoint_fixture")
private enum CheckpointModule {}

// MARK: - CheckpointPeer

@PythonExportedClass("Peer", module: CheckpointModule.self)
private final class CheckpointPeer {
    @PythonProperty
    let value: Int

    private var peer: CheckpointPeer?
    private var reference: Python::Reference?

    @PythonInit
    init(_ value: Int = 0) {
        self.value = value
    }

    @PythonFunction
    func retain(_ peer: CheckpointPeer) {
        self.peer = peer
    }

    @PythonFunction
    func recall() -> CheckpointPeer? {
        peer
    }

    @PythonFunction
    func remember(_ reference: Python::Reference) {
        self.reference = reference
    }

    @PythonFunction
    func remembered() -> Python::Reference? {
        reference
    }
}

@Test(.timeLimit(.minutes(3)))
func checkpointedEvaluationRestoresOriginalPythonAndSwiftObjects() async throws {
    let python = try await Python::Runtime()
    let session = try await python.session(modules: [CheckpointModule.self], transactional: true)
    defer { await session.close() }

    let prepared = try await session.evaluate("""
    import sys
    from checkpoint_fixture import Peer

    holder = Peer()
    child = Peer(17)
    holder.retain(child)
    values = [{"nested": [1]}]
    holder.remember(values)
    alias = values
    nested = values[0]["nested"]

    root_count = sys.getrefcount(values)
    original_ids = id(child), id(values), id(nested)
    """)
    #expect(prepared.end == .finished)

    let error = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("""
        del child
        replacement = holder.recall()
        assert id(replacement) != original_ids[0]
        assert replacement.value == 17
        nested.extend([2, 3])
        values.append(4)
        holder.remember(values)
        print("diagnostic")
        raise ValueError("checkpoint fixture")
        """, filename: "r2")
    }
    #expect(error.traceback.contains("checkpoint fixture"))
    #expect(error.traceback.contains("r2"))
    #expect(error.output.stdout == "diagnostic\n")

    let restored = try await session.evaluate("""
    assert (id(child), id(values), id(nested)) == original_ids
    assert holder.recall() is child and child.value == 17
    assert alias is values and nested is values[0]["nested"]
    assert values == [{"nested": [1]}]
    assert "replacement" not in globals()
    assert sys.getrefcount(values) == root_count - 1
    try:
        holder.remembered()
    except ReferenceError:
        pass
    else:
        raise AssertionError("A speculative Swift reference escaped rollback")
    """)
    #expect(restored.end == .finished)
}

// MARK: - PublicationError

private enum PublicationError: Swift::Error, Equatable {
    case failed
}

@Test(.timeLimit(.minutes(3)))
func rollbackKeepsAnotherInterpreterAlive() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(transactional: true)
    let other = try await runtime.session()
    defer {
        await session.close()
        await other.close()
    }
    try await session.initialize()

    await #expect(throws: PublicationError.failed) {
        try await session.evaluate("""
        import threading
        speculative_thread = threading.Thread()
        """, committing: { _ in
            // Start a peer after the snapshot to exercise registry links owned by the peer.
            try await other.initialize()
            throw PublicationError.failed
        })
    }
    #expect(try await session.evaluate("'speculative_thread' in globals()")
        .output
        .stdout == "False\n")
    await session.close()
    #expect(try await other.evaluate("6 * 7").output.stdout == "42\n")
}

@Test(.timeLimit(.minutes(3)))
func checkpointedEvaluationWaitsForHostPublication() async throws {
    let python = try await Python::Runtime()
    let session = try await python.session(.source("values = [1]"), transactional: true)
    defer { await session.close() }

    await #expect(throws: PublicationError.failed) {
        try await session.evaluate("values.append(2)", committing: { seal in
            try seal.seal()
            throw PublicationError.failed
        })
    }

    #expect(try await stopDuringPublication(in: session) == .stopped)

    try await checkDeadlineDuringPublication(in: session)

    let committed = try await session.evaluate("""
    assert values == [1]
    values.append(4)
    print("ready")
    """, committing: { seal in
        try seal.seal()
        #expect(!session.stop())
    })
    #expect(committed.end == .finished)
    #expect(committed.output.stdout == "ready\n")
    #expect(try await session.evaluate("assert values == [1, 4]").end == .finished)
}

private func checkDeadlineDuringPublication(in session: Python::Session) async throws {
    let attemptedPublication = Mutex(false)
    let expired = try await session.evaluate(
        "values.append(5)",
        timeout: .milliseconds(500),
        committing: { seal in
            attemptedPublication.withLock { $0 = true }
            try await Task.sleep(for: .seconds(1))
            try seal.seal()
        },
    )
    #expect(attemptedPublication.withLock { $0 })
    #expect(expired.end == .timedOut)
}

private func stopDuringPublication(in session: Python::Session) async throws -> Python::Execution
    .End
{
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (resume, gate) = AsyncStream<Void>.makeStream()
    defer {
        signal.finish()
        gate.finish()
    }

    async let evaluation = session.evaluate("values.append(3)", committing: { seal in
        signal.yield(())
        _ = await nextSignal(from: resume)
        try seal.seal()
    })
    _ = await nextSignal(from: entered)
    #expect(session.stop())
    gate.yield(())

    return try await evaluation.end
}

//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - CounterModule

@PythonModule("counter_base")
private enum CounterModule {}

// MARK: - LabeledCounterModule

@PythonModule("counter_child")
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

@PythonClass("Counter", module: CounterModule.self)
private class Counter {
    let context: Python::Context

    @PythonProperty
    var value: Int
    private var secret = 0
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
        self.context = context
        CounterLifetime.instanceCount.withLock { $0 += 1 }
        try self.$value(value)
        try self.$default(7)
        if linkToSelf {
            try self.$next(self)
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
    func invoke() throws -> Int {
        guard let reference = try self.callback else {
            return -1
        }
        let context = self.context
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

@PythonClass("Labeled", module: LabeledCounterModule.self)
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

@PythonClass(module: LabeledCounterModule.self)
private final class ExistingInstance: Sendable {
    let context: Python::Context

    @PythonProperty
    var note: String?
    @PythonProperty
    let number = 42

    init(in context: Python::Context) {
        self.context = context
    }

    @PythonFunction
    func asynchronous() async -> Int {
        await Task.yield()
        return number
    }
}

@Test
func exportedClassInheritanceAndGarbageCollection() async throws {
    let runtime = try await Python::Runtime()
    // The base's module is pulled in by the exported Swift inheritance graph.
    let session = try await runtime.session(modules: [LabeledCounterModule.self])
    _ = try await session.evaluate("""
    from counter_base import Counter
    from counter_child import Labeled, echo, echoList, ExistingInstance
    import inspect, weakref, gc

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

    linked = Counter(12, True)
    assert linked.value == 12 and linked.next is linked
    dead_linked = weakref.ref(linked)
    del linked
    gc.collect()
    assert dead_linked() is None
    """)
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
    do {
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
    _ = try await session.evaluate("gc.collect(); assert dead() is None")
    #expect(CounterLifetime.instanceCount.withLock { $0 } == 0)

    do {
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
    _ = try await session.evaluate("gc.collect()")
    #expect(CounterLifetime.instanceCount.withLock { $0 } == 0)
    await session.close()
}

@Test
func classIdentityAndSessionGenerations() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [LabeledCounterModule.self])
    let other = try await runtime.session(modules: [LabeledCounterModule.self])
    let peer = try await session.enqueue { ExistingInstance(in: $0) }
    try await session.set(peer, forKey: "peer")
    let decoded = try await session.get("peer", as: ExistingInstance.self)
    #expect(decoded === peer)
    _ = try await session
        .evaluate("import weakref; dead_peer = weakref.ref(peer); peer.note = 'old'")
    try await session.remove("peer")
    _ = try await session.evaluate("import gc; gc.collect(); assert dead_peer() is None")
    try await session.set(peer, forKey: "peer")
    _ = try await session.evaluate("assert peer.note is None and peer.number == 42")
    await #expect(throws: (any Swift.Error).self) { try await other.set(peer, forKey: "peer") }
    let managed = try await session.enqueue { _ in try Python::Managed(peer) }
    _ = try await session.evaluate("assert await peer.asynchronous() == 42")
    try await session.set(42, forKey: "value")
    let value: Int = try await managed { peer in
        await Task.yield()
        return try await peer.context.get("value")
    }
    #expect(value == 42)
    try await session.reset()
    await #expect(throws: Python::Exception.self) { try await session.set(peer, forKey: "peer") }
    await #expect(throws: Python::Exception.self) { try await managed { $0.number } }
    await session.close()
    await other.close()
}

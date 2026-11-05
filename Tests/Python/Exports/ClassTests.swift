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
    @PythonProperty
    var value: Int
    private var secret = 0
    @PythonProperty
    private(set) var readOnlyValue = 7
    @PythonProperty @PythonReference
    let callback: Python::Field<Python::Reference?> = .init()

    @PythonInit
    init(_ value: Int = 0) throws {
        guard value >= 0 else {
            throw Python::Exception(
                name: "ValueError",
                message: "negative",
            )
        }
        self.value = value
        CounterLifetime.instanceCount.withLock { $0 += 1 }
    }

    deinit { CounterLifetime.instanceCount.withLock { $0 -= 1 } }

    @PythonFunction
    func increment(_ amount: Int = 1) -> Int {
        secret += 1
        value += amount
        return value
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
    func invoke(context: borrowing Python::Context) throws -> Int {
        guard let reference = try callback.get(in: context) else {
            return -1
        }
        let function = try reference.resolve(in: context)
        return try function.call().decode()
    }
}

extension Counter {
    @PythonFunction
    func extended(_ amount: Int) -> Int {
        value + amount
    }

    @PythonProperty
    var doubled: Int {
        get { value * 2 }
        set { value = newValue / 2 }
    }
}

// MARK: - LabeledCounter

@PythonClass("Labeled", module: LabeledCounterModule.self)
private final class LabeledCounter: Counter {
    @PythonProperty
    let label: String

    @PythonInit
    init(_ value: Int, label: String = "label") throws {
        self.label = label
        try super.init(value)
    }

    override func describe() -> String {
        "child:" + label
    }
}

// MARK: - ExistingInstance

@PythonClass(module: LabeledCounterModule.self)
private final class ExistingInstance: Sendable {
    @PythonProperty @PythonReference
    let note: Python::Field<String?> = .init()
    @PythonProperty
    let number = 42
}

// MARK: - SharedFieldState

private enum SharedFieldState {
    static let field: Python::Field<String?> = .init()
}

// MARK: - SharedFieldInstance

@PythonClass(module: LabeledCounterModule.self)
private final class SharedFieldInstance: Sendable {
    @PythonReference
    let field: Python::Field<String?> = SharedFieldState.field
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
    assert x.value == 10 and x.doubled == 20
    x.__init__(999, label='changed')
    assert x.value == 10 and x.label == 'x'
    assert not hasattr(x, 'secret')
    assert list(inspect.signature(Counter.increment).parameters) == ['self', 'amount']
    """)
    _ = try await session.evaluate("""
    rejected = [
        (AttributeError, lambda: setattr(x, 'readOnlyValue', 8)),
        (AttributeError, lambda: setattr(x, 'other', 1)),
        (TypeError, lambda: setattr(Counter, 'extra', 1)),
        (TypeError, lambda: ExistingInstance()),
        (ValueError, lambda: Counter(-1)),
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
    x.callback = lambda captured=x: captured.value + 1
    assert x.invoke() == 11
    dead = weakref.ref(x)
    del x
    """)
    _ = try await session.evaluate("gc.collect(); assert dead() is None")
    #expect(CounterLifetime.instanceCount.withLock { $0 } == 0)
    await session.close()
}

@Test
func classIdentityAndSessionGenerations() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [LabeledCounterModule.self])
    let other = try await runtime.session(modules: [LabeledCounterModule.self])
    let peer = ExistingInstance()
    try await session.set("peer", to: peer)
    let decoded = try await session.get("peer", as: ExistingInstance.self)
    #expect(decoded === peer)
    _ = try await session
        .evaluate("import weakref; dead_peer = weakref.ref(peer); peer.note = 'old'")
    try await session.remove("peer")
    _ = try await session.evaluate("import gc; gc.collect(); assert dead_peer() is None")
    try await session.set("peer", to: peer)
    _ = try await session.evaluate("assert peer.note is None and peer.number == 42")
    await #expect(throws: (any Swift.Error).self) { try await other.set("peer", to: peer) }
    let fieldOwner = SharedFieldInstance()
    try await session.set("field_owner", to: fieldOwner)
    let rejected = SharedFieldInstance()
    for _ in 0 ..< 2 {
        let exception = try await #require(throws: Python::Exception.self) {
            try await session.set("rejected", to: rejected)
        }
        #expect(exception.name == "TypeError")
        #expect(exception.message.contains("shared"))
    }
    try await session.reset()
    await #expect(throws: (any Swift.Error).self) { try await session.set("peer", to: peer) }
    await session.close()
    await other.close()
}

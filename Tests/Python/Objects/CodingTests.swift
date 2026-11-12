//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - CodingPoint

private struct CodingPoint: Python::Encodable, Python::Decodable, Sendable, Equatable {
    let x: Int
    let labels: [String]

    init(x: Int, labels: [String]) {
        self.x = x
        self.labels = labels
    }

    func encode(to encoder: inout Python::Encoder) throws {
        try encoder.encode(x, forKey: "x")
        try encoder.encode(labels, forKey: "labels")
    }

    init(from decoder: borrowing Python::Decoder) throws {
        x = try decoder.decode(Int.self, forKey: "x")
        labels = try decoder.decode([String].self, forKey: "labels")
    }
}

// MARK: - CodingPacket

private struct CodingPacket: ~Copyable, Sendable, Python::Encodable, Python::Decodable {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    init(from decoder: borrowing Python::Decoder) throws {
        count = try decoder.decode()
    }

    func encode(to encoder: inout Python::Encoder) throws {
        try encoder.encode(count)
    }
}

@Test
func typedRecordsAndOptionalsRoundTripThroughTheNamespace() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    let point = CodingPoint(x: 42, labels: ["hello", "Привет\0🐍"])

    try await session.set(point, forKey: "point")
    try await session.set(Int?.none, forKey: "nothing")
    _ = try await session.evaluate("""
    assert point["x"] == 42
    assert nothing is None
    """)

    #expect(try await session.get("point", as: CodingPoint.self) == point)
    #expect(try await session.get("nothing", as: Int?.self) == nil)
    try await session.enqueue { context in
        let settings = try context.object("point")
        try settings.set(43, forKey: "x")
        let value: Int = try settings.get("x")
        #expect(value == 43)

        let array = try context.encode([1, 2])
        try array.set(42, at: 1)
        let element = try array.object(1)
        try array.remove(1)
        #expect(try element.decode(as: Int.self) == 42)
    }
    await session.close()
}

@Test
func integersRoundTripAtTheirWidthAndRejectOverflow() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    defer { await session.close() }

    try await session.set(UInt64.max, forKey: "maximum")
    try await session.set(UInt128.max, forKey: "wide_maximum")
    _ = try await session.evaluate("""
    assert maximum == 2**64 - 1
    assert wide_maximum == 2**128 - 1

    class WideInt(int):
        def __str__(self):
            return "0"

    wide_subclass = WideInt(2**127 + 42)
    """)

    #expect(try await session.get("maximum", as: UInt64.self) == .max)
    #expect(try await session.get("wide_maximum", as: UInt128.self) == .max)

    try await expectPythonException("OverflowError") {
        _ = try await session.get("maximum", as: Int8.self)
    }

    try await expectPythonException("TypeError") {
        _ = try await session.get("wide_subclass", as: UInt128.self)
    }
}

@Test
func moveOnlyValuesCanCrossTheSessionQueue() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    try await session.set(CodingPoint(x: 42, labels: []), forKey: "point")

    let packet = try await session.enqueue { context in
        let point = try context.get("point", as: CodingPoint.self)
        try context.set(point.x + 1, forKey: "count")
        return CodingPacket(count: try context.get("count"))
    }
    #expect(try await session.get("count", as: Int.self) == 43)
    #expect(packet.count == 43)

    try await session.set(CodingPacket(count: 42), forKey: "packet")
    let decoded = try await session.get("packet", as: CodingPacket.self)
    #expect(decoded.count == 42)
    let optionalPacket = try await session.get("packet", as: CodingPacket?.self)
    if let optionalPacket {
        #expect(optionalPacket.count == 42)
    } else {
        Issue.record("Expected a packet when decoding a non-nil optional.")
    }
    await session.close()
}

@Test
func attributesSupportNULAndModuleNamesRejectIt() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    _ = try await session.evaluate(#"""
    class Named:
        pass

    named = Named()
    named.value = 7
    setattr(named, "value\x00tail", 42)
    """#)

    try await session.enqueue { context in
        let named = try context.object("named")
        #expect(try named.attribute("value\0tail").decode(as: Int.self) == 42)
        try named.setAttribute("value\0tail", to: 43)
        #expect(try named.attribute("value\0tail").decode(as: Int.self) == 43)

        try expectPythonException("ValueError") {
            _ = try context.import(module: "sys\0tail")
        }
    }
    await session.close()
}

@Test
func typedNamesFollowTheSessionLifecycle() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    try await session.set(1, forKey: "removed")
    try await session.set(2, forKey: "until_reset")

    func expectMissing(_ name: String) async throws {
        let error = try await #require(throws: Python::Exception.self) {
            try await session.get(name, as: Int.self)
        }
        #expect(error.name == "NameError", "Expected \(name) to be absent.")
    }

    try await session.remove("removed")
    try await expectMissing("removed")

    try await session.reset()
    try await expectMissing("until_reset")

    await session.close()
    await #expect(throws: Python::Session.Error.self) {
        try await session.set(3, forKey: "closed")
    }
}

@Test
func pythonReferencesAreInterpreterBound() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    let other = try await runtime.session()
    _ = try await session.evaluate("""
    import weakref
    class Thing: pass
    thing = Thing()
    weak = weakref.ref(thing)
    """)
    let weak = try await session.enqueue { context in
        let object = try context.object("thing")
        return try Python::WeakReference(object, in: context)
    }

    func isAlive() async throws -> Bool {
        try await session.enqueue { context in
            let value = try context.object(weak)
            return value != nil
        }
    }

    do {
        let root = try await session.enqueue { context in
            try context.object("thing").retain(in: context)
        }
        try await session.set(root, forKey: "alias")
        _ = try await session.evaluate("assert thing is alias")
        try await session.remove("thing")
        try await session.remove("alias")
        #expect(try await isAlive())
        await #expect(throws: (any Swift::Error).self) { try await other.set(root, forKey: "x") }
    }

    _ = try await session.evaluate("import gc; gc.collect(); assert weak() is None")
    #expect(try await !isAlive())

    let root: Python::Reference = try await session.get("weak")
    try await session.reset()
    await #expect(throws: (any Swift::Error).self) { try await session.set(root, forKey: "old") }
    await session.close()
    await other.close()
}

@Test(.timeLimit(.minutes(1)))
func asynchronousContextOperationsUseSeparateQueueTurns() async throws {
    let runtime = try await Python::Runtime()
    let starts = Mutex(0)
    let initialize = Python::Module.Function("initialize", synchronous: { _ in
        starts.withLock { $0 += 1 }
        return .none
    })
    let session = try await runtime.session(
        .source("import startup_probe; startup_probe.initialize()"),
        moduleDefinitions: [.init("startup_probe", functions: [initialize])],
    )

    let value: Int = try await session.enqueue { context in
        await Task.yield()
        try await context.set(42, forKey: "answer")
        let value: Int = try await context.get("answer")
        try await context.remove("answer")
        return value
    }
    #expect(value == 42)

    let (started, signal) = AsyncStream<Void>.makeStream()
    let (resume, gate) = AsyncStream<Void>.makeStream()
    let pending = Task {
        defer { signal.finish() }
        try await session.enqueue { context in
            try await context.set(1, forKey: "old")
            signal.finish()
            for await _ in resume {}
            try await context.set(2, forKey: "old")
        }
    }
    defer {
        gate.finish()
        pending.cancel()
    }

    for await _ in started {}
    let old: Int = try await session.get("old")
    #expect(old == 1)
    try await session.reset()
    gate.finish()
    try await expectPythonException("ReferenceError") {
        _ = try await pending.value
    }
    #expect(starts.withLock { $0 } == 1)
    try await session.set(3, forKey: "fresh")
    #expect(starts.withLock { $0 } == 2)
    await session.close()
}

@Test
func dictionaryKeyCollisionsThrow() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(.source(#"data = {'\u00e9': None, 'e\u0301': 2}"#))
    defer { await session.close() }

    try await expectPythonException("ValueError") {
        _ = try await session.get("data", as: [String: Int?].self)
    }

    try await expectPythonException("ValueError") {
        _ = try await session.get("data", as: Python::Value.self)
    }
}

// MARK: - RecoveringEncoding

private struct RecoveringEncoding: Python::Encodable {
    let tuple: Python::Reference

    func encode(to encoder: inout Python::Encoder) throws {
        try tuple.encode(to: &encoder)
        try expectPythonException("TypeError") {
            try encoder.encode(12, at: 0)
        }
        try encoder.encode(42)
    }
}

@Test
func encoderCanRecoverFromAnInvalidContainerShape() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(.source("pair = (0, 1)"))
    defer { await session.close() }

    try await session.enqueue { context in
        let tuple = try context.object("pair").retain(in: context)
        try context.set(RecoveringEncoding(tuple: tuple), forKey: "result")
        #expect(try context.get("result", as: Int.self) == 42)
    }
}

@Test
func typedExportedFunctions() async throws {
    let module = makeTypedModule()
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [module])

    try await withSession(session) { session in
        _ = try await session.evaluate("""
        import typed
        assert typed.next() == 1
        assert typed.next() == 2
        assert typed.next(value=40) == 40
        assert await typed.point({'x': 41, 'labels': ['a']}) == {'x': 42, 'labels': ['a']}
        typed.injected(42)
        assert injected_value == 42
        """)
    }
}

private func makeTypedModule() -> Python::Module {
    let defaults = Mutex(0)
    let next = Python::Module.Function("next", parameters: [
        .init("value", as: Int.self, hasDefaultValue: true),
    ], call: { arguments, _, encoder in
        try arguments.withArgument(Int.self, parameter: 0, default: {
            defaults.withLock { value in
                value += 1
                return value
            }
        }) { value in try encoder.encode(value) }
    })

    let point = Python::Module.Function("point", parameters: [
        .init("value", as: CodingPoint.self),
    ], start: { arguments, _ in
        let value = try arguments.get(0, as: CodingPoint.self)
        return Python::Module.Function.makeOperation {
            await Task.yield()
            return CodingPoint(x: value.x + 1, labels: value.labels)
        }
    })

    let injected = Python::Module.Function("injected", parameters: [
        .init("context", as: Python::Context.self),
        .init("value", as: Int.self),
    ], call: { arguments, context, encoder in
        let value = try arguments.get(0, as: Int.self)
        try context.set(value, forKey: "injected_value")
        try encoder.encodeNil()
    })

    return Python::Module("typed", functions: [next, point, injected])
}

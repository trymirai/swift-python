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
        x = try decoder["x"].get()
        labels = try decoder["labels"].get()
    }
}

// MARK: - CodingPacket

private struct CodingPacket: ~Copyable, Sendable, Python::Encodable, Python::Decodable {
    let count: Int
    init(count: Int) {
        self.count = count
    }

    init(from decoder: borrowing Python::Decoder) throws {
        count = try decoder.get()
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

    try await session.set("point", to: point)
    try await session.set("nothing", to: Int?.none)
    _ = try await session.evaluate("""
    assert point["x"] == 42
    assert nothing is None
    """)

    #expect(try await session.get("point", as: CodingPoint.self) == point)
    #expect(try await session.get("nothing", as: Int?.self) == nil)
    await session.close()
}

@Test
func integersRoundTripAtTheirWidthAndRejectOverflow() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()

    try await session.set("maximum", to: UInt64.max)
    try await session.set("wide_maximum", to: UInt128.max)
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
    let overflow = try await #require(throws: Python::Exception.self) {
        try await session.get("maximum", as: Int8.self)
    }
    #expect(overflow.name == "OverflowError")
    let subclass = try await #require(throws: Python::Exception.self) {
        try await session.get("wide_subclass", as: UInt128.self)
    }
    #expect(subclass.name == "TypeError")
    await session.close()
}

@Test
func moveOnlyValuesCanCrossTheSessionQueue() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    try await session.set("point", to: CodingPoint(x: 42, labels: []))

    let packet = try await session.enqueue { context in
        let point = try context["point"].get(as: CodingPoint.self)
        try context["count"].set(point.x + 1)
        return CodingPacket(count: try context["count"].get())
    }
    #expect(try await session.get("count", as: Int.self) == 43)
    #expect(packet.count == 43)

    try await session.set("packet", to: CodingPacket(count: 42))
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
        let named = try context["named"].object()
        #expect(try named.attribute("value\0tail").decode(as: Int.self) == 42)
        do {
            _ = try context.import(module: "sys\0tail")
            Issue.record("Expected a NUL module name to fail.")
        } catch let exception as Python::Exception {
            #expect(exception.name == "ValueError")
        }
    }
    await session.close()
}

@Test
func typedNamesFollowTheSessionLifecycle() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    try await session.set("removed", to: 1)
    try await session.set("until_reset", to: 2)

    try await session.remove("removed")
    let missing = try await #require(throws: Python::Exception.self) {
        try await session.get("removed", as: Int.self)
    }
    #expect(missing.name == "NameError")

    try await session.reset()
    let reset = try await #require(throws: Python::Exception.self) {
        try await session.get("until_reset", as: Int.self)
    }
    #expect(reset.name == "NameError")

    await session.close()
    await #expect(throws: Python::SessionError.self) {
        try await session.set("closed", to: 3)
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
        let object = try context["thing"].object()
        return try Python::WeakReference(object, in: context)
    }
    do {
        let root: Python::Reference = try await session.get("thing")
        try await session.set("alias", to: root)
        _ = try await session.evaluate("assert thing is alias")
        try await session.remove("thing")
        try await session.remove("alias")
        let isAlive = try await session.enqueue { context in
            let value = try weak.resolve(in: context)
            return value != nil
        }
        #expect(isAlive)
        await #expect(throws: (any Swift.Error).self) { try await other.set("x", to: root) }
    }
    _ = try await session.evaluate("import gc; gc.collect(); assert weak() is None")
    let isReleased = try await session.enqueue { context in
        let value = try weak.resolve(in: context)
        return value == nil
    }
    #expect(isReleased)
    let root: Python::Reference = try await session.get("weak")
    try await session.reset()
    await #expect(throws: (any Swift.Error).self) { try await session.set("old", to: root) }
    await session.close()
    await other.close()
}

// MARK: - CodingDefaults

private final class CodingDefaults: Sendable {
    let next: Mutex = .init(0)
}

@Test
func typedExportedFunctions() async throws {
    let defaults = CodingDefaults()
    let next = Python::Module.Function("next", parameters: [
        .init("value", as: Int.self, hasDefaultValue: true),
    ], call: { arguments, _, encoder in
        try arguments.withArgument(Int.self, parameter: 0, default: {
            defaults.next.withLock { value in
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
        try context["injected_value"].set(value)
        try encoder.encodeNil()
    })
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [.init(
        "typed",
        functions: [next, point, injected],
    )])
    _ = try await session.evaluate("""
    import typed
    assert typed.next() == 1
    assert typed.next() == 2
    assert typed.next(value=40) == 40
    assert await typed.point({'x': 41, 'labels': ['a']}) == {'x': 42, 'labels': ['a']}
    typed.injected(42)
    assert injected_value == 42
    """)
    await session.close()
}

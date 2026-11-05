//
//  Created by Anton Spivak
//

import Python
import Synchronization
import Testing

// MARK: - ExportDefaults

private enum ExportDefaults {
    static let counter: Mutex = .init(0)
    static func next() -> Int {
        counter.withLock { value in
            value += 1
            return value
        }
    }
}

// MARK: - AutomaticModule

@PythonModule("automatic")
private enum AutomaticModule {
    private static let seed = 41
    @PythonFunction
    static func selfDefault(_ value: Int = Self.seed) -> Int {
        value + 1
    }

    @PythonFunction
    static func sum(_ lhs: Int, _ rhs: Int = 2) -> Int {
        lhs + rhs
    }

    @PythonFunction
    static func middle(_ left: Int = 1, _ right: Int) -> Int {
        left + right
    }

    @PythonFunction
    static func next(_ value: Int = ExportDefaults.next()) -> Int {
        value
    }

    @PythonFunction
    static func optional(_ value: Int? = 42) -> Int? {
        value
    }

    @PythonFunction("integer")
    static func format(_ value: Int) -> String {
        "int:\(value)"
    }

    @PythonFunction("floating")
    static func format(_ value: Double) -> String {
        "float:\(value)"
    }

    @PythonFunction
    static func publish(_ value: Int, context: borrowing Python::Context) throws {
        try context["published"].set(value)
    }
}

extension AutomaticModule {
    @PythonFunction
    static func extended(_ value: Int) -> Int {
        value + 1
    }
}

@PythonFunction(module: AutomaticModule.self)
private func multiply(_ lhs: Int, _ rhs: Int) -> Int {
    lhs * rhs
}

// MARK: - ConfiguredModule

@PythonModule("configured")
private actor ConfiguredModule {
    let prefix: String
    init(prefix: String) {
        self.prefix = prefix
    }

    @PythonFunction
    func greeting(_ name: String) -> String {
        "\(prefix):\(name)"
    }
}

// MARK: - UnselectedModule

@PythonModule("unselected")
private enum UnselectedModule {
    @PythonFunction
    static func untouched() -> Int {
        1
    }
}

@Test
func automaticModuleDiscovery() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [AutomaticModule.self])
    _ = try await session.evaluate("""
    import automatic, inspect, sys

    assert automatic.sum(40) == 42
    assert automatic.selfDefault() == 42
    assert automatic.middle(right=41) == 42
    assert automatic.middle(20, 22) == 42
    try:
        automatic.middle(42)
    except TypeError:
        pass
    else:
        raise AssertionError("Expected the required 'right' argument to be rejected")

    assert automatic.multiply(6, 7) == 42
    assert automatic.extended(41) == 42
    assert automatic.integer(42) == 'int:42'
    assert automatic.floating(1.5) == 'float:1.5'
    assert automatic.next() + 1 == automatic.next()
    assert automatic.next(99) == 99
    assert automatic.optional() == 42
    assert automatic.optional(None) is None

    automatic.publish(42)
    assert published == 42
    assert list(inspect.signature(automatic.publish).parameters) == ['value']
    assert 'def sum(' in inspect.getsource(automatic.sum)
    assert 'unselected' not in sys.modules
    """)
    await session.close()
}

@Test
func configuredActorModule() async throws {
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(moduleInstances: [ConfiguredModule(prefix: "first")])
    let second = try await runtime.session(moduleInstances: [ConfiguredModule(prefix: "second")])
    _ = try await first.evaluate("""
    import configured, inspect
    assert inspect.iscoroutinefunction(configured.greeting)
    assert list(inspect.signature(configured.greeting).parameters) == ['name']
    assert 'async def greeting(' in inspect.getsource(configured.greeting)
    assert await configured.greeting('x') == 'first:x'
    """)
    _ = try await second
        .evaluate("import configured; assert await configured.greeting('x') == 'second:x'")
    await #expect(throws: (any Swift.Error).self) {
        try await runtime.session(modules: [ConfiguredModule.self])
    }
    await first.close()
    await second.close()
}

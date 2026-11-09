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
}

extension AutomaticModule {
    @PythonFunction
    static func extended(_ value: Int) -> Int {
        value + 1
    }

    @PythonFunction
    static func multiply(_ lhs: Int, _ rhs: Int) -> Int {
        lhs * rhs
    }
}

// MARK: - ConfiguredModule

@PythonModule("configured")
private final class ConfiguredModule {
    private init(prefix: String) {}

    @PythonFunction
    static func greeting(_ name: String, prefix: String) async -> String {
        await Task.yield()
        return "\(prefix):\(name)"
    }
}

// MARK: - InvalidContextModule

@PythonModule("invalid_context")
private enum InvalidContextModule {
    @PythonFunction
    static func injected(_ context: Python::Context) {}
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
    try await evaluateInFreshSession("""
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

    assert 'def sum(' in inspect.getsource(automatic.sum)
    assert 'unselected' not in sys.modules
    """, modules: [AutomaticModule.self])
}

@Test
func staticModuleDoesNotRequireAnInstance() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(modules: [ConfiguredModule.self])
    defer { await session.close() }

    _ = try await session.evaluate("""
    import configured, inspect
    assert inspect.iscoroutinefunction(configured.greeting)
    assert list(inspect.signature(configured.greeting).parameters) == ['name', 'prefix']
    assert 'async def greeting(' in inspect.getsource(configured.greeting)
    assert await configured.greeting('x', prefix='first') == 'first:x'
    """)

    let error = try await #require(throws: Python::Exception.self) {
        try await runtime.session(modules: [InvalidContextModule.self])
    }
    #expect(error.message.contains("cannot take a Python Context"))
}

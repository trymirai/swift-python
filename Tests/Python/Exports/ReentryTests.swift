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
    let read = Python::Module.Function("read", start: { _, _ in
        Python::Module.Function.makeOperation {
            let session = try #require(target.withLock { $0 })
            return try await session.get("value", as: Int.self)
        }
    })
    let reset = Python::Module.Function("reset", start: { _, _ in
        Python::Module.Function.makeOperation {
            let session = try #require(target.withLock { $0 })
            try await session.reset()
        }
    })
    let imports = Python::Module.Function("imports", start: { _, _ in
        Python::Module.Function.makeOperation {
            let session = try #require(target.withLock { $0 })
            try await session.replaceImportPaths([])
        }
    })
    let evaluate = Python::Module.Function("evaluate") { _ in
        let session = try #require(target.withLock { $0 })
        _ = try await session.evaluate("1")
        return .none
    }
    let module = Python::Module("reentry", functions: [read, reset, imports, evaluate])
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(moduleDefinitions: [module])
    target.withLock { $0 = session }
    _ = try await session.evaluate("""
    import reentry
    value = 42
    for function in (reentry.read, reentry.reset, reentry.imports, reentry.evaluate):
        try:
            await function()
        except RuntimeError as error:
            assert 'own session' in str(error)
        else:
            raise AssertionError(f"Expected {function.__name__} to reject reentry")
    assert value == 42
    """)
    #expect(try await session.get("value", as: Int.self) == 42)
    await session.close()
}

@Test(.timeLimit(.minutes(1)))
func callbackChainCannotAwaitAnAncestor() async throws {
    let targets = Mutex<(first: Python::Session, second: Python::Session)?>(nil)
    defer { targets.withLock { $0 = nil } }
    let forward = Python::Module.Function("forward", start: { _, _ in
        Python::Module.Function.makeOperation {
            let second = try #require(targets.withLock { $0?.second })
            _ = try await second.evaluate("import chain; await chain.back()")
        }
    })
    let back = Python::Module.Function("back", start: { _, _ in
        Python::Module.Function.makeOperation {
            let first = try #require(targets.withLock { $0?.first })
            return try await first.get("value", as: Int.self)
        }
    })
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(moduleDefinitions: [.init("chain", functions: [forward])])
    let second = try await runtime.session(moduleDefinitions: [.init("chain", functions: [back])])
    targets.withLock { $0 = (first, second) }
    _ = try await first.evaluate("""
    import chain
    value = 42
    try:
        await chain.forward()
    except RuntimeError as error:
        assert 'own session' in str(error)
    else:
        raise AssertionError("Expected the callback to reject reentry into its ancestor")
    """)
    #expect(try await first.get("value", as: Int.self) == 42)
    await first.close()
    await second.close()
}

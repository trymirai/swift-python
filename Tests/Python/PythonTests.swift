//
//  Created by Anton Spivak
//

internal import libpythontestsupport
import Python
import Testing

@Test
func embeddedStandardLibrarySupportsSourceResourcesAndOverrides() async throws {
    #if RemoteDebugging && (os(macOS) || os(Linux))
    let remoteDebugging = "True"
    #else
    let remoteDebugging = "False"
    #endif

    let code = #"""
    import _swift_python, inspect, json, sys, sysconfig
    from importlib.resources import files
    from importlib.util import find_spec
    from pathlib import Path
    from tempfile import TemporaryDirectory

    assert json.__file__ == "embedded:/stdlib/json/__init__.py"
    assert "def dumps(" in inspect.getsource(json.dumps)
    resources = files("json")
    assert "def dumps(" in resources.joinpath("__init__.py").read_text()
    assert "decoder.py" in {entry.name for entry in resources.iterdir()}

    with TemporaryDirectory() as directory:
        override = Path(directory) / "this.py"
        override.touch()
        sys.path.insert(0, directory)
        try:
            assert find_spec("this").origin == str(override)
        finally:
            sys.path.pop(0)

    assert not _swift_python.is_directory("jso")
    assert _swift_python.children("").count("json") == 1
    for lookup in (_swift_python.read, _swift_python.module, _swift_python.children,
                   _swift_python.is_file, _swift_python.is_directory):
        try:
            lookup("json/__init__.py\x00ignored")
        except ValueError:
            pass
        else:
            raise AssertionError("Embedded names must reject NUL characters")

    assert sysconfig.get_config_var("MULTIARCH") == sys.implementation._multiarch
    assert sys.is_remote_debug_enabled() is \#(remoteDebugging)
    assert sysconfig.get_config_var("Py_REMOTE_DEBUG") == int(\#(remoteDebugging))
    """#
    try await evaluateInFreshSession(code)
}

@Test
func bundledNativeModulesAreUsable() async throws {
    try await evaluateInFreshSession("""
    import _decimal, bz2, ctypes, lzma, sqlite3, ssl, zlib
    from compression import zstd
    from xml.parsers import expat

    callback = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int)(lambda value: value + 1)
    assert callback(41) == 42
    assert _decimal.Decimal("0.1") + _decimal.Decimal("0.2") == _decimal.Decimal("0.3")
    assert expat.ParserCreate().Parse("<root/>", True)
    assert ssl.create_default_context().verify_mode == ssl.CERT_REQUIRED

    payload = b"swift-python"
    for codec in (bz2, lzma, zlib, zstd):
        assert codec.decompress(codec.compress(payload)) == payload

    with sqlite3.connect(":memory:") as database:
        database.execute("CREATE VIRTUAL TABLE documents USING fts5(text)")
        assert database.serialize()

    """)
}

func evaluateInFreshSession(
    _ source: String,
    modules: [any Python::ModuleHost.Type] = [],
) async throws {
    let session = try await Python::Runtime().session(modules: modules)
    try await withSession(session) { session in
        _ = try await session.evaluate(source)
    }
}

@Test
func interactiveSessions() async throws {
    let runtime = try await Python::Runtime()
    let first = try await runtime.session(directory: "/tmp")
    let second = try await runtime.session()

    async let initial = first.evaluate("""
    import sys
    counter = 40
    assert sys.path[0] == "/tmp"
    def fail():
        raise ValueError("from an earlier block")
    print("diagnostic", file=sys.stderr)
    counter + 2
    """, filename: "<initial>")
    async let other = second.evaluate("""
    import asyncio
    assert "counter" not in globals()
    await asyncio.sleep(0)
    7
    """)

    let (firstExecution, secondExecution) = try await (initial, other)
    #expect(firstExecution.end == .finished)
    #expect(firstExecution.output.stdout == "42\n")
    #expect(firstExecution.output.stderr == "diagnostic\n")
    #expect(secondExecution.end == .finished)
    #expect(secondExecution.output.stdout == "7\n")

    try await checkInteractiveErrors(in: first)
    #expect(try await first.evaluate("counter").output.stdout == "40\n")

    try await first.reset()
    #expect(try await first.evaluate("'counter' in globals()").output.stdout == "False\n")
    #expect(try await second.evaluate("_").output.stdout == "7\n")

    await first.close()
    await #expect(throws: Python::Session.Error.self) {
        try await first.evaluate("1")
    }
    await second.close()
}

private func checkInteractiveErrors(in session: Python::Session) async throws {
    let error = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("print('before'); fail()", filename: "<failure>")
    }
    #expect(error.output.stdout == "before\n")
    #expect(error.output.stderr == error.traceback)
    #expect(error.traceback.contains("<failure>"))
    #expect(error.traceback.contains("<initial>"))
    #expect(error.traceback.contains("raise ValueError"))

    for source in ["raise SystemExit(1)", "raise KeyboardInterrupt()"] {
        await #expect(throws: Python::ExecutionError.self) {
            try await session.evaluate(source)
        }
    }
}

#if os(macOS)
@Test
func systemTrust() {
    #expect(CPython_CheckSystemTrust() == 0)
}
#endif

@Test
func sourceInitialization() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session(.source("counter = 40\nprint('initialized')"))

    #expect(await session.startupOutput?.stdout == "initialized\n")
    #expect(try await session.evaluate("counter += 2; counter").output.stdout == "42\n")

    try await session.reset()
    #expect(try await session.evaluate("counter").output.stdout == "40\n")
    await session.close()

    let error = try await #require(throws: Python::ExecutionError.self) {
        try await runtime.session(.source("raise ValueError('initialization failed')"))
    }
    #expect(error.traceback.contains("ValueError: initialization failed"))
    #expect(error.output.stderr == error.traceback)
}

func withSession(
    _ session: Python::Session,
    _ test: (Python::Session) async throws -> Void,
) async rethrows {
    do {
        try await test(session)
    } catch {
        await session.close()
        throw error
    }
    await session.close()
}

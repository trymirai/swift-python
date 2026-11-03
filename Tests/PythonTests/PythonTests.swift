//
//  Created by Anton Spivak
//

internal import libpythontestsupport
import Testing

@Test
func embeddedPython() {
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

    if sys.platform in ("darwin", "linux"):
        import _curses, _curses_panel, readline
    """#
    let result = code.withCString { unsafe CPython_CheckEmbedding($0) }
    #expect(result == 0)
}

#if os(macOS)
@Test
func systemTrust() {
    #expect(CPython_CheckSystemTrust() == 0)
}
#endif

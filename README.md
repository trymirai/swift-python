# swift-python

Embed CPython 3.16.0a1 and its standard library in a Swift app. Call Python libraries
from Swift, or let Python import functions and classes written in Swift.

![Swift 6.4](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)
![macOS, iOS and Mac Catalyst 26.4+](https://img.shields.io/badge/macOS%20%7C%20iOS%20%7C%20Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)
![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)

[Installation](#installation) · [Calling Python](#calling-python-from-swift) · [Exporting Swift](#calling-swift-from-python) · [Interactive sessions](#interactive-sessions) · [Scripts and packages](#scripts-and-packages)

## Quick start

A `Runtime` creates sessions. Each session has its own interpreter and keeps its imports
and variables between calls.

```swift
import Python

let runtime = try await Runtime()
let session = try await runtime.session()
defer { await session.close() }

try await session.set([19, 7, 11], forKey: "samples")
_ = try await session.evaluate("""
from statistics import median
middle = median(samples)
""")

let middle: Int = try await session.get("middle")
print(middle) // 11
```

## Installation

Add the package to `Package.swift` and the `Python` product to your target.

```swift
// Package dependencies
.package(url: "https://github.com/trymirai/swift-python.git", branch: "main")

// Target dependencies
.product(name: "Python", package: "swift-python")
```

Building CPython requires Swift 6.4 with SwiftPM's `experimentalCGen` support, GNU make,
`patch`, and a C/C++ toolchain in `/usr/bin`. Apple builds use the Xcode SDK. Linux builds
also need the zlib and bzip2 development packages.

The default build includes `asyncio`, sockets, TLS, SQLite, XML parsing, and compression.
Enable the `RemoteDebugging` trait for CPython remote debugging on macOS and Linux.

## Calling Python from Swift

Inside `session.enqueue`, call Python classes and methods directly. This creates a
`textwrap.TextWrapper` by name and retains its bound `wrap` method for later use.

```swift
let wrap: Python::Reference = try await session.enqueue { py in
    let textwrap = try py.import(module: "textwrap")
    let wrapperType = try textwrap.value(forAttribute: "TextWrapper")
    let wrapper = try wrapperType(keywords: [("width", 8)])
    return try wrapper(methodNamed: "wrap").retain(in: py)
}

let lines: [String] = try await session.call(wrap, arguments: ["red blue green"])
print(lines) // ["red blue", "green"]
```

Within the closure, `try wrapper(methodNamed: "wrap")("red blue green")` calls the method
immediately. `session.call` accepts positional and keyword arguments and awaits a
returned coroutine or future before decoding it.

| What you need                          | What to use                                                                                                                                                       |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| An independent Swift value             | Decoding a `String` or `[Int]` gives Swift its own data. `Python::Value` handles mixed lists and string-keyed dictionaries.                                       |
| The same Python object on a later call | A `Python::Reference` retains the object in its owning session. Reset or close invalidates the reference.                                                         |
| A reference that allows collection     | A `Python::WeakReference` resolves to `nil` after collection. Creating one for a built-in `list` raises `TypeError`.                                              |
| Access to Python storage               | An `Object` stays in the synchronous closure. `utf8()` borrows a string's UTF-8 view. `withSpan(as:)` borrows a contiguous buffer with a matching element format. |

`value(forKey:)` reads a mapping entry and `value(at:)` reads a sequence element.
`valueIfPresent(forAttribute:)` returns `nil` for a missing attribute. An attribute set
to `None` returns an `Object` that decodes to `nil` as `String?`. Custom Swift values
can implement `Python::Encodable` and `Python::Decodable`.

### Typed bindings

Declare just the members you use. This binding exposes Python's `with_suffix` as
`withSuffix(_:)` and reads the filename from the returned path.

```swift
@PythonImportedClass(module: "pathlib", name: "PurePosixPath")
struct PosixPath {
    @PythonInit
    init(_ path: String, in context: Context) throws

    @PythonProperty(isReadOnly: true)
    var name: String

    @PythonFunction("with_suffix")
    func withSuffix(_ suffix: String) throws -> PosixPath
}

let filename = try await session.enqueue { py in
    let path = try PosixPath("reports/summary.txt", in: py)
    return try path.withSuffix(".md").name
}
print(filename) // summary.md
```

An async initializer runs on the session's Python event loop. Instance methods use the
same session, so `put` and `get` operate on one queue.

```swift
@PythonImportedClass(module: "asyncio", name: "Queue")
struct IntQueue {
    @PythonInit
    init(in session: Session) async throws

    @PythonFunction
    func put(_ value: Int) async throws

    @PythonFunction
    func get() async throws -> Int
}

let queue = try await IntQueue(in: session)
try await queue.put(42)
let next = try await queue.get()
print(next) // 42
```

A session runs one top-level call at a time. If `get()` needs to wait for a producer,
schedule the producer and consumer together in Python with `asyncio.gather`.

## Calling Swift from Python

Register a Swift module when opening a session. Python can then import it by name.
Here `invert` mutates the caller's `bytearray` in place.

```swift
@PythonExportedModule("image_tools")
enum ImageTools {
    @PythonFunction
    static func invert(_ pixels: inout MutableSpan<UInt8>) {
        for index in pixels.indices {
            pixels[index] = 255 - pixels[index]
        }
    }
}

let images = try await runtime.session(modules: [ImageTools.self])
defer { await images.close() }

let image = try await images.evaluate("""
from image_tools import invert
pixels = bytearray([0, 64, 255])
invert(pixels)
print(list(pixels))
""")
print(image.output.stdout, terminator: "") // [255, 191, 0]
```

Both immutable `bytes` and a strided view such as `memoryview(pixels)[::2]` raise
`BufferError` when passed to `invert`. Use `Span<UInt8>` for contiguous read-only
data. Call back into Python after the borrow ends.

Python can `await` an `async` Swift export. If the export takes a `Context`, the bridge
supplies it so Swift can call back into Python. To raise a Python `ValueError`, throw
`Python::Failure(.valueError, message: "empty image")`. [Callback examples](Tests/Python/Exports/CallbackAccessTests.swift)

Use `@PythonExportedClass` for a Swift class with a Python initializer, properties, or
methods. To hold an exported instance across calls, `Python::Managed` retains its Python
wrapper. [Exported class example](Tests/Python/Exports/ClassTests.swift)

Generate type hints with `try await Python::Stubs([ImageTools.self]).write(to: directory)`.
The generator replaces the contents of that directory with `.pyi` files.

## Interactive sessions

`evaluate` accepts top-level `await` and displays the last expression in a cell.
Read `output.stdout` and `output.stderr` on the result, stream them as they arrive,
or pass absolute file paths in `redirecting:`.

```swift
let notebook = try await runtime.session(history: .init(outputs: .last(20)))
defer { await notebook.close() }

_ = try await notebook.evaluate("""
import asyncio
print("Starting")
await asyncio.sleep(0, result=42)
""") { _, text in
    print(text, terminator: "")
}
// Starting
// 42
```

The next cell can read the source as `In[1]` and `42` as `Out[1]`.
On a Python exception, `Python::Failure` carries its class name, traceback, and captured
output. Here `row` stays in the session after `int(row)` fails.

```swift
do {
    _ = try await notebook.evaluate("""
    row = "n/a"
    print("Reading row")
    int(row)
    """)
} catch let failure as Python::Failure where failure.kind == .exception(.valueError) {
    print(failure.output?.stdout ?? "", terminator: "") // Reading row
}
```

Cancelling a queued evaluation throws `CancellationError`. An interrupted evaluation
that already started returns `end == .stopped` with its captured output. Cancelling a
pending `session.call` throws `CancellationError`.

## Scripts and packages

A standalone script can declare dependencies in PEP 723 metadata. Save this as `preview.py`.

```python
# /// script
# dependencies = ["Markdown>=3.8,<4"]
# ///

import sys
from markdown import markdown


def render(source):
    return markdown(source, extensions=["tables"])


if __name__ == "__main__":
    print(render(sys.argv[1]))
```

`runtime.run` takes an absolute path, resolves dependencies, and passes arguments in
`sys.argv`. Each run gets a fresh session that closes when the script finishes.

```swift
let project = "/path/to/project"
let run = try await runtime.run(script: "\(project)/preview.py", arguments: ["# Notes"])
print(run.output.stdout, terminator: "") // <h1>Notes</h1>
```

The installer accepts compatible pure-Python wheels from PyPI. Packages that import a
native extension need that extension in the app build. Use `packageIndex` for a private
index and `cacheDirectory` for a custom cache location.

### Project sessions

To reuse `preview.py` as a module, put `Markdown>=3.8,<4` in the project's `requirements.txt`.
Without that file, the runtime reads `dependencies` from the `[project]` table in `pyproject.toml`.
Open one session with `runtime.session(.project(directory: project, module: "preview"))`.
For several sessions, prepare the dependencies once.

```swift
let resources = try await runtime.prepare(project: project, in: "/path/to/preparations")
let preview = try await runtime.session(resources, module: "preview")
defer { await preview.close() }

let render: Python::Reference = try await preview.get("render")
let html: String = try await preview.call(render, arguments: ["**draft**"])
print(html) // <p><strong>draft</strong></p>
```

Sessions opened from `resources` share package files and keep separate globals.
Preparation reuses compatible versions unless you pass `update: true`.

- **Across app launches.** The default environment is temporary. An absolute `environmentDirectory` keeps local installations across launches. One session can use that directory at a time.
- **Existing packages.** Pass a `site-packages` directory with its distribution metadata as a `.directory` source. Lookup order is local installations, session sources, then runtime sources. With no explicit session sources, a project discovers its own `site-packages` or compatible `.venv`.
- **Package changes.** If `session.packages` returns `.requiresReset` for a change, call `session.reset()` and retry. Reset clears globals and invalidates references.

### Offline bundles

Bundle the project module and its dependencies at build time. The app can open the ZIP
as a package source and render Markdown offline.

```swift
let archive = "/path/to/preview.zip"
try await runtime.bundle(project: project, module: "preview", to: archive)

let offline = try await Runtime(packages: [.archive(archive)])
let bundled = try await offline.session(.module("preview"))
defer { await bundled.close() }

let page = try await bundled.evaluate("print(render('# Offline'))")
print(page.output.stdout, terminator: "") // <h1>Offline</h1>
```

Use `.embedded` with a SwiftPM `.embedInCode` resource. A custom ZIP must have the contents
of `site-packages` at its root. For cross-platform bundles, `targetEnvironment` selects
conditional dependencies using the destination's PEP 508 markers.

## Files and subprocesses

`directory:`, `importPaths:`, and project and package roots grant read access. Relative
paths resolve against the process working directory. A `Session.Delegate` can approve
additional reads and writes through Python's file APIs. If a script has a delegate,
the delegate also approves reading the script itself.

Enable `Runtime(options: [.subprocesses])` to use Python's `subprocess` on macOS,
Mac Catalyst, and Linux. For a child with piped output, call `communicate()` in the
evaluation that starts it. Child processes and native libraries such as SQLite use the
app's operating-system permissions.

## License

Swift Python uses the [MIT License](LICENSE). Licenses for CPython and bundled libraries
are listed in [NOTICE](NOTICE).

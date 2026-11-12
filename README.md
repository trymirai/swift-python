# swift-python

[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![iOS 26.4+](https://img.shields.io/badge/iOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Mac Catalyst 26.4+](https://img.shields.io/badge/Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)](#requirements)

Run Python code from Swift, use Python libraries, and expose Swift functions and classes to Python.
The package includes CPython 3.16.0a1 and its standard library.

## Installation

Add the package to `Package.swift` and the `Python` product to your target.

```swift
.package(url: "https://github.com/trymirai/swift-python.git", branch: "main")
```

```swift
.product(name: "Python", package: "swift-python")
```

For version `0.2.0`, see [its README](https://github.com/trymirai/swift-python/tree/v0.2.0#installation).

## Quick start

```swift
import Python

let runtime = try await Runtime()
let session = try await runtime.session()
try await session.set([4, 8, 12], forKey: "samples")

let execution = try await session.evaluate("""
from statistics import median
median_sample = median(samples)
print(median_sample)
""")

let median = try await session.get("median_sample", as: Int.self) // 8
print(execution.output.stdout, terminator: "") // 8
await session.close()
```

A session preserves Python globals between evaluations. Use `set(_:forKey:)` and `get(_:as:)`
to exchange values with Swift, and call `close()` when the session is no longer needed.

Use `Python::Value` for dynamic values. Custom Swift types can conform to `Python::Encodable`
and `Python::Decodable`.

### Python objects and live output

Use `enqueue` to import Python modules, access objects, and call Python functions.
Decode results to Swift values before returning them from the closure.

```swift
let console = try await runtime.session()
let settings: [String: Int] = try await console.enqueue { context in
    let json = try context.import(module: "json")
    return try json.attribute("loads").call(#"{"retries":3}"#).decode()
}

let job = try await console.evaluate("""
import asyncio
print("Starting")
await asyncio.sleep(10)
""", timeout: .seconds(1)) { _, text in
    print(text, terminator: "")
}
print(job.end) // timedOut
await console.close()
```

`evaluate` supports top-level `await`, captures output, and accepts a live output handler.
Cancel the calling task to interrupt Python, or set `timeout:` to limit execution time.
Use `redirecting:` with absolute paths to save output to files.

Startup code runs on the first Python operation. Call `initialize(redirecting:)` to run it
explicitly, and read `startupOutput` for its output.

`history: .init()` enables `In[n]` (source) and `Out[n]` (last expression result).
The `inputs` and `outputs` limits accept `.last(n)` or `.unlimited`; `history: nil` disables both.
Sources use memory or `redirecting: [.source: path]`. Eviction deletes source files.

Pass `transactional: true` when creating a session to restore Python state after a failed or
interrupted evaluation. File changes persist.

Run slow, synchronous Python calls outside the main actor and limit concurrent calls.

### Call Swift from Python

Declare a module with `@PythonExportedModule`, mark its functions with `@PythonFunction`, and
register it with `session(modules:)`.

```swift
@PythonExportedModule("buffers")
enum Buffers {
    @PythonFunction
    static func invert(_ pixels: inout MutableSpan<UInt8>) {
        for index in pixels.indices {
            pixels[index] = 255 - pixels[index]
        }
    }
}

let bufferSession = try await runtime.session(modules: [Buffers.self])
let image = try await bufferSession.evaluate("""
import buffers
pixels = bytearray([0, 64, 255])
buffers.invert(pixels)
print(list(pixels))
""")
print(image.output.stdout, terminator: "") // [255, 191, 0]
await bufferSession.close()
```

`MutableSpan` edits the Python buffer in place.

### Export a Swift class

Use `@PythonExportedClass` to expose a Swift class. Mark its initializer, properties, and methods
with `@PythonInit`, `@PythonProperty`, and `@PythonFunction`. Register its module with `modules:`.

```swift
@PythonExportedModule("counters")
enum Counters {}

@PythonExportedClass(module: Counters.self)
final class Counter {
    @PythonProperty
    var value: Int

    @PythonInit
    init(_ value: Int) throws {
        try $value(value)
    }

    @PythonFunction
    func increment() throws {
        try $value { $0 + 1 }
    }
}

let counters = try await runtime.session(modules: [Counters.self])
let result = try await counters.evaluate("""
from counters import Counter
counter = Counter(4)
counter.increment()
print(counter.value)
""")
print(result.output.stdout, terminator: "") // 5
await counters.close()
```

Use Python's `help()` to view exported types and documentation, and `inspect.signature()` to
inspect function parameters and return types.

```python
import inspect
import counters

help(counters.Counter)
print(inspect.signature(counters.Counter.increment))
```

### Generate type stubs

```swift
let stubs = Python::Stubs([Counters.self])
try await stubs.write(to: "/path/to/project/typings")
```

`write(to:)` replaces the destination directory with `.pyi` files for the selected
modules. The path must be absolute. Unknown types are emitted as `object`.

For Pyright, set `"stubPath": "typings"` in `pyrightconfig.json`.

### Import a Python class

Use `@PythonImportedClass` to declare Swift bindings for a Python class. Targets that declare
these bindings require `.enableExperimentalFeature("Lifetimes")` in `swiftSettings`.

```swift
@PythonImportedClass(module: "pathlib", name: "PurePosixPath")
struct PosixPath {
    @PythonProperty(isReadOnly: true)
    var name: String

    @PythonFunction("with_suffix")
    func withSuffix(_ suffix: String) throws -> PosixPath
}

let paths = try await runtime.session()
_ = try await paths.evaluate("""
from pathlib import PurePosixPath
report = PurePosixPath("reports/summary.txt")
""")
let report = try await paths.get("report", as: PosixPath.self)
let name = try await paths.enqueue { _ in
    try report.withSuffix(".md").name
}
print(name) // summary.md
await paths.close()
```

Read an existing instance with `get(_:as:)`. Access its properties and methods inside `enqueue`
on the same session, or in a Swift callback invoked by that session. Imported types can also
be parameters and return values of functions marked `@PythonFunction`.

To create an instance from Swift, call
`try context.construct(PosixPath.self, arguments: ["reports/summary.txt"])` inside `enqueue`.

`Python::DateTime` and `Python::Path` provide bindings for Python dates and paths. Create them
inside `enqueue` with `try Python::DateTime(instant, in: context)` or
`try Python::Path(filePath, in: context)`. Convert them to Swift with
`try Foundation::Date(datetime)` or `try FilePath(path)`.

When calling another session from a Swift callback, pass the callback's `Context` through `in:`,
for example `try await other.evaluate(source, in: context)` or `await other.close(in: context)`.

## Scripts and projects

Scripts run in new sessions and receive arguments in `sys.argv`. Declare dependencies with
[PEP 723 inline metadata](https://packaging.python.org/en/latest/specifications/inline-script-metadata/).
Save this example as `version_label.py`.

```python
# /// script
# dependencies = ["packaging"]
# ///

import sys
from packaging.version import Version

print(Version(sys.argv[1]).public)
```

Use absolute paths for scripts, projects, and environments. For the project example, create
`reporting/__init__.py` under the project root. The session imports `reporting` and uses its globals.

```swift
let script = try await runtime.run(script: "/path/to/version_label.py", arguments: ["v2.1rc1+ci"])
print(script.output.stdout, terminator: "") // 2.1rc1

let projectSession = try await runtime.session(
    .project(directory: "/path/to/project", module: "reporting"),
    environmentDirectory: "/path/to/environments/reporting",
)
print(try await projectSession.get("__name__", as: String.self)) // reporting
await projectSession.close()
```

Top-level `await` is supported in scripts, `.source(...)`, and source modules selected with
`.project(...)` or `.module(...)`. Startup completes before the first evaluation.
Regular imports retain standard Python semantics.

## Environments and dependencies

Declare project dependencies in `requirements.txt` or `[project].dependencies` in `pyproject.toml`.
If both are present, `requirements.txt` takes precedence. Dependencies are installed before
startup. Package installation supports pure-Python wheels.

Use `Runtime(packageIndex:)` to select a package index; the default is PyPI.
Use `Runtime(cacheDirectory:)` to choose a directory for cached wheels.

Set `environmentDirectory:` to an absolute path to reuse installed packages between sessions.
Only one session may use an environment directory at a time. Without this parameter, the
environment is temporary and is removed when the session closes.

Pass package sources as `.directory(path)`, `.archive(path)`, or `.embedded(bytes)` in `packages:`.
Installed packages in the environment take precedence over session sources, followed by runtime
sources. Within each list, earlier sources take precedence. A version conflict raises a
resolution error.

Project sessions without explicit session sources also use the project's `site-packages` or
`.venv`. These package directories must be inside the project.

Use `session.packages` to inspect installed versions, install or uninstall requirements, and
resolve dependencies. `resolve()` preserves compatible installed versions; `update()` selects
versions from the package index.

If a package operation returns `.requiresReset`, call `session.reset()` and repeat the operation.
Reset clears Python state, so retrieve any Python objects again afterward.

### Bundle a project for offline use

```swift
let archive = "/path/to/reporting.zip"
try await runtime.bundle(project: "/path/to/project", module: "reporting", to: archive)
let offline = try await Runtime(packages: [.archive(archive)])
let bundled = try await offline.session(.module("reporting"))
try await bundled.initialize()
await bundled.close()
```

To embed the ZIP in the executable, add it as a SwiftPM `.embedInCode` resource and pass its bytes
as `.embedded(...)`.

## File access

Sessions can read files under `directory:`, `importPaths:`, project roots, and package sources.
Use `Session.Delegate.shouldAllowFileAccess(_:)` to approve additional reads and writes.
Denied file operations raise Python's `PermissionError`.

For scripts, the delegate must approve reading the script file. This approval applies only to
that file. Without a delegate, the script's containing directory is readable.

Some native modules are unavailable. Importing them raises `ModuleNotFoundError`.

### Subprocesses

`Runtime(options: [.subprocesses])` enables Python's `subprocess` on macOS, Mac Catalyst, and Linux.
Child processes use the application's OS permissions. The session's file delegate does not
control their file access.

`evaluate` waits for child processes to exit. Its timeout applies to both Python code and child
processes. Cancelling the task or reaching the timeout stops child processes.

Set `close_fds=True`. Use `communicate()` to read piped output, or redirect output to a file.
Call `wait()` or `communicate()` in the same evaluation that starts the child. A child left
running with an open pipe causes an execution error and is stopped.

## Requirements

- Swift 6.4 with SwiftPM's `experimentalCGen` support.
- macOS, iOS, and Mac Catalyst 26.4 or later. Apple builds require Xcode with the target SDK.
- Linux with glibc or musl, plus zlib and bzip2 development packages.
- GNU make, `patch`, and the host C/C++ toolchain in `/usr/bin`.

See the optional library and remote debugging traits in [Package.swift](Package.swift).

## Credits

Thanks to the [CPython contributors](https://github.com/python/cpython). Bundled sources and licenses
are listed in [NOTICE](NOTICE).

## License

This package is available under the [MIT License](LICENSE).

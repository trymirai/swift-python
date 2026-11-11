# swift-python

[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![iOS 26.4+](https://img.shields.io/badge/iOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Mac Catalyst 26.4+](https://img.shields.io/badge/Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)](#requirements)

Embed CPython 3.16.0a1 and its standard library in Swift with the static SwiftPM product `Python`.

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

Sessions keep globals between calls. Use `Python::Value` for dynamic values and
`Python::Encodable` or `Python::Decodable` for custom Swift types.

### Python objects and live output

`enqueue` gives scoped access to Python objects on the interpreter thread.

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

Call `stop()` to interrupt evaluation. Use absolute paths in `redirecting:` for file-backed streams.
Startup runs on the first Python operation or through `initialize(redirecting:)`, with output
captured in `startupOutput`.

### Call Swift from Python

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

Select the exported module with `modules:` to make its classes importable from Python.

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

### Import a Python class

Add `.enableExperimentalFeature("Lifetimes")` to `swiftSettings` for targets that declare
imported classes. Use `enqueue` on the owning session for synchronous member access.

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

## Scripts and projects

Scripts run in fresh sessions and receive arguments in `sys.argv`. Save this as `version_label.py`.
[PEP 723](https://packaging.python.org/en/latest/specifications/inline-script-metadata/)

```python
# /// script
# dependencies = ["packaging"]
# ///

import sys
from packaging.version import Version

print(Version(sys.argv[1]).public)
```

Use absolute paths. For the project example, add `reporting/__init__.py` under the project root.
The session imports `reporting` and uses its globals.

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

## Environments and dependencies

`requirements.txt` takes precedence over `[project].dependencies` in `pyproject.toml`.
The runtime resolves dependencies before user code runs and installs missing packages as
pure-Python wheels.
`Runtime(packageIndex:)` selects the index (PyPI by default).

Pass an absolute `environmentDirectory:` to reuse local installs and their resolution. One
session can hold the directory at a time. Temporary environments are removed on close.
`Runtime(cacheDirectory:)` sets the separate wheel cache.

The first source that provides a distribution wins.

1. Local installations in the managed environment.
2. Sources passed to `session(packages:)`, in list order. With an empty list, a project checks
   `site-packages` at its root, then the embedded Python version's `site-packages` in `.venv`.
   The selected directory must resolve inside the project.
3. Sources passed to `Runtime(packages:)`, in list order.

Pass `.directory(path)`, `.archive(path)`, or `.embedded(bytes)` to select sources explicitly.
Resolution fails on a version conflict even when a later source has a compatible version.

`session.packages` inspects selected versions and manages local requirements and overrides.
`resolve()` prefers compatible installed versions, while `update()` re-resolves from the index.
A wheel change after startup returns `.requiresReset`. Call `session.reset()` to clear Python
state and invalidate references, then retry. [Package API](Sources/Python/Environment/Session+Packages.swift)

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

Sessions allow reads from `directory:`, `importPaths:`, project roots, and package sources.
`Session.Delegate.shouldAllowFileAccess(_:)` decides access to other paths and writes. Denied
Python file operations raise `PermissionError`. Embedded native modules use an allowlist.

For scripts, the delegate checks the source before reading it. Approval covers the script file.
Without a delegate, the script directory is a read root.

In transactional sessions, rollback restores Python state and session-owned descriptor positions.
Filesystem changes persist.

### Subprocesses

`Runtime(options: [.subprocesses])` enables Python's `subprocess` on macOS, Mac Catalyst, and Linux.
Children use the application's OS permissions outside the file delegate's scope.

After Python returns, the execution waits for its direct children within the remaining timeout.
Stop, cancellation, and timeout terminate their process groups. The runtime signals any
remaining group members before reaping the leader.
`close_fds=True` is required. Drain pipes with `communicate()` or redirect output to a file.
Returning with a running child and an open pipe raises an execution error and stops its group.
Collect exit status with `wait()` or `communicate()` during the launching execution.

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

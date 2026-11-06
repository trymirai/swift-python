# swift-python

[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![iOS 26.4+](https://img.shields.io/badge/iOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Mac Catalyst 26.4+](https://img.shields.io/badge/Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)](#requirements)

Embed CPython 3.16.0a1 in a Swift application. The static `Python` library
includes the interpreter and selected standard library modules.

## Usage

### Sessions

Add the `Python` product to your SwiftPM target.

```swift
import Python

let runtime = try await Python::Runtime()
let session = try await runtime.session(.source("counter = 40"))

let output = try await session.evaluate("counter + 2")
print(output.stdout, terminator: "") // 42
```

Each session has its own interpreter and keeps its Python globals between
calls. `evaluate` supports top-level `await` and captures `stdout` and `stderr`.

Set `timeout` to limit evaluation time or call `stop()` to request interruption.
`ExecutionError` carries captured output and includes a traceback for Python
exceptions. Call `reset()` to rerun startup on the next evaluation or `close()`
to end the session.

### Typed values

```swift
try await session.set([1, 2, 3], forKey: "numbers")
_ = try await session.evaluate("numbers.reverse()")
let numbers = try await session.get("numbers", as: [Int].self) // [3, 2, 1]
```

Built-in codecs cover integers, floats, booleans, strings, optionals, arrays,
and string-keyed dictionaries. Use `Python::Value` for dynamic data. For your
own types, implement `Python::Encodable` and `Python::Decodable`.

```swift
struct Point: Sendable {
    let x: Int
    let y: Int
}

extension Point: Python::Encodable, Python::Decodable {
    func encode(to encoder: inout Python::Encoder) throws {
        try encoder.encode(x, forKey: "x")
        try encoder.encode(y, forKey: "y")
    }

    init(from decoder: borrowing Python::Decoder) throws {
        x = try decoder.decode(Int.self, forKey: "x")
        y = try decoder.decode(Int.self, forKey: "y")
    }
}

try await session.set(Point(x: 1, y: 2), forKey: "point")
let point = try await session.get("point", as: Point.self)
```

### Interpreter access

A synchronous `enqueue` closure runs on the session's interpreter thread. Keep
Python objects and borrowed views inside the closure and return a `Sendable`
value.

```swift
let x: Int = try await session.enqueue { context in
    let object = try context.object("point")
    return try object.get("x")
}
```

Use `context.import(module:)` to import a module and `remove(_:)` to delete a
name. In an async `enqueue` closure, each awaited context operation is queued
separately.

### Standard streams

```swift
let streams = Python::StandardIO(
    stdin: "/work/input.txt",
    stdout: "/work/stdout.log"
)
_ = try await session.evaluate("print(input())", standardIO: streams)
let bytes = try await streams.read(.stdout, from: 0, maximumByteCount: 4096)
```

Use absolute paths with existing parent directories. Redirected output appends
to files and leaves the corresponding `Output` strings empty. Omit `stdin` for
EOF. Use `onOutput` for live text chunks or `startupIO` to configure startup
streams.

### Scripts

`run(script:)` runs a UTF-8 file as `__main__` in a fresh session and sets
`sys.argv`. It installs dependencies declared in the script's
[PEP 723 metadata](https://packaging.python.org/en/latest/specifications/inline-script-metadata/).

```python
# /// script
# dependencies = ["pypdf>=5"]
# ///

import sys

from pypdf import PdfReader

print(len(PdfReader(sys.argv[1]).pages))
```

```swift
let pages = try await runtime.run(
    script: "/scripts/page_count.py",
    arguments: ["/work/invoice.pdf"],
    environmentDirectory: "/work/script-environment"
)
print(pages.stdout, terminator: "")
```

Supply `environmentDirectory` to reuse installed dependencies across runs.

### Projects and packages

Open a flat-layout project by passing its directory and startup module.

```text
project/
├── pyproject.toml
└── assistant/
    └── __init__.py
```

```swift
let projectSession = try await runtime.session(
    .project(directory: "/projects/project", module: "assistant"),
    environmentDirectory: "/work/project-environment"
)
```

The runtime installs compatible pure-Python wheels before importing the module.
Its globals become the session namespace. `requirements.txt` takes precedence
over `[project].dependencies` in `pyproject.toml`.

Use `install(requirements:)` and `uninstall(packages:)` to change session
packages, and `installedPackages()` to list their versions. `resolvePackages()`
rereads project requirements. `updatePackages()` selects current compatible
versions. If a package change throws `SessionError.resetRequired`, call
`reset()` and retry.

### Embedded packages

`bundle(project:module:to:)` writes a ZIP of resolved packages and an optional
startup module.

```swift
try await runtime.bundle(
    project: "/projects/project",
    module: "assistant",
    to: "/work/packages.zip"
)
```

Add `.embedInCode("Resources/packages.zip")` to your target's resources and pass
`.embedded(PackageResources.packages_zip)` to `Runtime(packages:)`. Use
`.archive(path)` or `.directory(path)` for packages on disk.

### Swift modules

```swift
@PythonModule("example")
enum Example {
    @PythonFunction
    static func greeting(_ name: String = "world") async -> String {
        "Hello, \(name)!"
    }
}

let exampleSession = try await runtime.session(modules: [Example.self])
let greeting = try await exampleSession.evaluate("""
import example
print(await example.greeting())
""")
print(greeting.stdout, terminator: "") // Hello, world!
```

Python uses Swift's local parameter names for keyword arguments. Swift defaults
apply to omitted arguments. Async exports take and return owned `Sendable`
values. Async instance methods also require a `Sendable` receiver.

### Swift classes

```swift
@PythonClass(module: Example.self)
final class Counter {
    let context: Python::Context

    @PythonProperty var value: Int

    @PythonInit
    init(_ value: Int = 0, in context: Python::Context) throws {
        self.context = context
        try self.$value(value)
    }

    @PythonFunction
    func increment(_ amount: Int = 1) throws -> Int {
        try self.$value { $0 + amount }
        return try self.value
    }
}

let count = try await exampleSession.evaluate("""
counter = example.Counter(40)
counter.increment(2)
""")
print(count.stdout, terminator: "") // 42
```

The `@PythonInit` initializer receives its `Context` automatically. Read a
stored `@PythonProperty var` with `try counter.value` and assign it with
`try counter.$value(42)`. Use `isReadOnly: true` to make it read-only in Python.

### Python references

Use `object.retain(in: context)` to keep a Python object alive across calls.
Open a `Reference` or `WeakReference` with `context.object(_:)`. A weak handle
resolves to `nil` once its target is collected. Handles expire when the
session resets or closes.

`Managed` keeps an exported Swift instance alive across calls.

```swift
let managed = try await exampleSession.enqueue { context in
    let counter = try context.get("counter", as: Counter.self)
    return try Python::Managed(counter)
}

let nextCount = try await managed { try $0.increment() } // 43
```

### Buffers

Synchronous exports accept `Span<Element>` and `inout MutableSpan<Element>` for
contiguous, aligned Python buffers in native format, and `UTF8Span` for strings.
Mutable spans require writable storage. For direct access from Swift, use
`Object.buffer(as:isWritable:)` with `withSpan` or `withMutableSpan`.
Finish the span closure before calling back into Python.

## Requirements

- Swift 6.4 with SwiftPM's `experimentalCGen` support.
- Git and a checkout with submodules initialized.
- GNU `make` and the host C/C++ toolchain (`cc`, `c++`, `ar`, `ranlib`) in
  `/usr/bin`. CPython's `configure` uses `/bin/sh` and standard Unix tools
  including `awk`, `grep`, and `sed`.
- For Apple builds, macOS 26.4 or later and Xcode with the target SDK. The
  minimum deployment version is 26.4 for macOS, iOS, and Mac Catalyst.
- For native Linux builds, the zlib and bzip2 development headers and libraries.
- Perl for OpenSSL source regeneration.

## Package Traits

| Trait             | Effect                                                                | Enabled by default |
| ----------------- | --------------------------------------------------------------------- | ------------------ |
| `OpenSSL`         | Bundles OpenSSL for `ssl` and `hashlib`                               | Yes                |
| `libffi`          | Bundles libffi for `ctypes`                                           | No                 |
| `libmpdec`        | Bundles libmpdec for `decimal`                                        | Yes                |
| `liblzma`         | Bundles liblzma for `lzma`                                            | Yes                |
| `Zstandard`       | Bundles Zstandard for `compression.zstd`                              | Yes                |
| `SQLite`          | Bundles SQLite for `sqlite3`                                          | No                 |
| `libedit`         | Bundles libedit and ncurses for `readline` and `curses` on Linux      | Yes                |
| `RemoteDebugging` | Enables remote debugging and the sampling profiler on macOS and Linux | No                 |

The default build also bundles libffi on iOS and Linux and SQLite on Linux.

## Third-Party Notices

Bundled components, upstream sources, and license references are listed in
[NOTICE](NOTICE).

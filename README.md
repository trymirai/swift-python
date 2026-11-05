# swift-python

[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![iOS 26.4+](https://img.shields.io/badge/iOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Mac Catalyst 26.4+](https://img.shields.io/badge/Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)](#requirements)

Embed CPython 3.16.0a1 in a Swift application with Swift Package Manager. The
static `Python` library includes the interpreter and a selected standard
library, with its sources and resources embedded in the binary.

## Usage

### Sessions

Each session has its own interpreter and persistent namespace.

```swift
import Python

let runtime = try await Python::Runtime()
let session = try await runtime.session(.source("counter = 40"))
let second = try await runtime.session()

let answer = try await session.evaluate("counter + 2")
let independent = try await second.evaluate("'counter' in globals()")

print(answer.stdout, terminator: "")       // 42
print(independent.stdout, terminator: "")  // False

await second.close()
```

`evaluate` supports top-level `await`. Use `reset()` to restart the interpreter
on the next evaluation with the same startup and packages. Use `close()` to
release the session.

Set `timeout` for a deadline that starts when evaluation begins. `stop()` requests
interruption and `isRunning` reports active work. `ExecutionError` carries
captured output and, for Python exceptions, a traceback.

### Typed values

`set(_:to:)` and `get(_:as:)` use `Python::Encodable` and `Python::Decodable`.
Built-in codecs cover integers, floats, booleans, strings, optionals, arrays and
string-keyed dictionaries. They decode exact Python builtins. Use `Python::Value`
for dynamic data.

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
        x = try decoder["x"].get()
        y = try decoder["y"].get()
    }
}

try await session.set("point", to: Point(x: 1, y: 2))
let point = try await session.get("point", as: Point.self)
```

### Interpreter access

`enqueue` runs a synchronous closure on the session's interpreter thread.
Keep scoped Python objects and views inside the closure. Return owned `Sendable`
values.

```swift
try await session.enqueue { context in
    let object = try context["point"].object()
    let x: Int = try object["x"].get()
    try context["answer"].set(x + 41)
    try context["point"].remove()
}
```

Use `context.import(module:)` to import a module. Missing names throw
`NameError`. Setting `nil` stores Python `None`. Use `remove()` to delete a name.

### Standard streams

```swift
let streams = Python::StandardIO(
    stdin: "/work/input.txt",
    stdout: "/work/stdout.log",
    stderr: "/work/stderr.log",
    traceback: "/work/traceback.txt"
)
let output = try await session.evaluate("print(input())", standardIO: streams)
let bytes = try await streams.read(.stdout, from: 0, maximumByteCount: 4096)
```

Supply absolute paths and create their parent directories. Redirected output
appends to files, preserves binary writes, and leaves the matching string in
`Output` empty. Other output is captured as text. Omitted input produces EOF.

Use `onOutput` for text chunks, `read(_:from:maximumByteCount:)` to read files
during execution, and `startupIO` to configure startup streams.

### Scripts

`run(script:)` runs a UTF-8 file as `__main__` in a fresh session and sets
`sys.argv`. The runtime installs dependencies declared in
[PEP 723 metadata](https://packaging.python.org/en/latest/specifications/inline-script-metadata/).

```python
# /// script
# requires-python = ">=3.13"
# dependencies = ["pypdf>=5"]
# ///

"""Process PDF documents."""
```

```swift
let output = try await runtime.run(
    script: "/scripts/invoices.py",
    arguments: ["/work/invoice.pdf"],
    environmentDirectory: "/work/script-environment",
    standardIO: streams
)
```

Supply `environmentDirectory` to reuse installed dependencies across runs.

### Projects and packages

Pass a flat-layout project and its startup module.

```text
project/
├── pyproject.toml
└── assistant/
    ├── __init__.py
    └── helpers.py
```

```swift
let runtime = try await Python::Runtime(
    packages: [.directory("/application/site-packages")],
    cacheDirectory: "/application/package-cache"
)
let session = try await runtime.session(
    .project(directory: "/projects/example", module: "assistant"),
    directory: "/work/example",
    environmentDirectory: "/work/example/python"
)
```

The runtime prepares dependencies before importing the startup module. Its
globals become the session namespace. Use `.module("assistant")` to start from
an existing module and `startupOutput` to read startup streams.

`requirements.txt` takes precedence over `[project].dependencies` in
`pyproject.toml`. Requirements use named PEP 508 declarations. The installer
selects compatible pure-Python wheels and treats application packages as fixed.

```swift
try await session.resolvePackages()
try await session.install(requirements: ["pypdf>=5"])
let versions = try await session.installedPackages()
try await session.reset()
try await session.updatePackages()
```

Use `uninstall(packages:)` to remove session-added requirements. If a change
would replace an imported distribution, the operation throws
`SessionError.resetRequired`. Call `reset()` and retry before evaluating again.

### Embedded packages

`bundle(project:module:to:)` writes a ZIP of resolved packages and an optional
startup module.

```swift
try await runtime.bundle(
    project: "/absolute/project",
    module: "assistant",
    to: "/absolute/packages.zip"
)
```

Add `.embedInCode("Resources/packages.zip")` to the owning Swift target's
resources and pass `.embedded(PackageResources.packages_zip)` in
`Runtime(packages:)`. Use `.archive(path)` for a ZIP stored as a file.

### Swift modules

```swift
import Python

@PythonModule("example")
enum Example {
    @PythonFunction(documentation: "Return a greeting.")
    static func greeting(_ name: String = "world") async -> String {
        "Hello, \(name)!"
    }
}

let runtime = try await Python::Runtime()
let session = try await runtime.session(modules: [Example.self])
let output = try await session.evaluate("""
import example
await example.greeting()
""")
```

`modules: [Example.self]` selects the linked exports. Use `moduleInstances:` for
configured `Sendable` hosts and `moduleDefinitions:` for manual definitions.
Free functions use `@PythonFunction(module: Example.self)`. When linking a
custom static archive, retain the object files containing exports.

Keyword arguments and Swift defaults are preserved. Async module functions
take and return owned `Sendable` values.

| Macro              | Export                             |
| ------------------ | ---------------------------------- |
| `@PythonModule`    | Swift namespace or configured host |
| `@PythonFunction`  | Function or instance method        |
| `@PythonClass`     | Swift class                        |
| `@PythonInit`      | Initializer callable from Python   |
| `@PythonProperty`  | Instance property                  |
| `@PythonReference` | Python-owned `Field<T>` storage    |

### Swift classes

```swift
@PythonClass(module: Example.self)
class Counter {
    @PythonProperty var value: Int
    private var updates = 0

    @PythonInit
    init(_ value: Int = 0) { self.value = value }

    @PythonFunction func increment(_ amount: Int = 1) -> Int {
        updates += 1
        value += amount
        return value
    }
}

extension Counter {
    @PythonProperty
    var doubled: Int { value * 2 }
}

@PythonClass(module: Example.self)
final class LabeledCounter: Counter {
    @PythonProperty
    let label: String

    @PythonInit init(_ value: Int, label: String) {
        self.label = label
        super.init(value)
    }
}
```

Python classes mirror Swift inheritance and include exported extension members.
Each wrapper owns one Swift instance. Mark one synchronous, non-failable
initializer with `@PythonInit` to allow construction from Python. Exported
instance methods are synchronous. Constants, get-only properties and properties
with private setters are read-only.

### Python references

`Object` holds a scoped reference and `BorrowedObject` borrows a callback
argument. `Reference` keeps a Python object alive across calls. `WeakReference`
resolves to `nil` after collection. Both handles expire on reset or close.

Use `@PythonReference` with `Field<T>` for callback references that can form
cycles. Python's collector can see these fields. Add `@PythonProperty` to expose
a field as a Python attribute.

```swift
@PythonClass(module: Example.self)
final class Listener {
    @PythonProperty
    @PythonReference
    let callback = Python::Field<Python::Reference?>()

    @PythonInit
    init() {}

    @PythonFunction func clear(context: borrowing Python::Context) throws {
        try callback.set(nil, in: context)
    }
}
```

### Buffers

Synchronous exports accept `Span<Element>`, `inout MutableSpan<Element>` and
`UTF8Span`. Buffers borrow contiguous, aligned, native-format storage from
`bytes`, `bytearray`, `array.array` or their memoryviews. Mutable spans require
writable storage. `UTF8Span` borrows Python's cached UTF-8.

Use `Object.buffer(as:isWritable:)` for explicit `withSpan` or
`withMutableSpan` access. Overlapping mutable views and Python reentry while a
view is active raise errors.

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

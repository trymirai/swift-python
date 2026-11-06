# swift-python

[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![iOS 26.4+](https://img.shields.io/badge/iOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Mac Catalyst 26.4+](https://img.shields.io/badge/Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)](#requirements)

Embed CPython 3.16.0a1 in a Swift application. The SwiftPM product `Python`
bundles the interpreter and standard-library modules in a static library.

## Installation

Add the package to `Package.swift`.

```swift
.package(url: "https://github.com/trymirai/swift-python.git", from: "0.2.0")
```

Add `Python` to your target's dependencies.

```swift
.product(name: "Python", package: "swift-python")
```

## Usage

### Run Python and exchange typed values

```swift
import Python

let runtime = try await Python::Runtime()
let session = try await runtime.session()
try await session.set([4, 8, 12], forKey: "samples")

let execution = try await session.evaluate("""
from statistics import median
median_sample = median(samples)
print(f"Processed {len(samples)} samples")
""")

let median = try await session.get("median_sample", as: Int.self)
print(execution.output.stdout, terminator: "") // Processed 3 samples
print(median) // 8
await session.close()
```

Each session has its own globals and keeps them between calls. `set` and `get`
support Swift scalars, optionals, arrays, and string-keyed dictionaries. Use
`Python::Value` for dynamic values or `Python::Encodable` and `Python::Decodable`
for your own types.

The following examples reuse `runtime` from this snippet.

### Call a Python library from Swift

```swift
let librarySession = try await runtime.session()
let settings: [String: Int] = try await librarySession.enqueue { context in
    let json = try context.import(module: "json")
    return try json.attribute("loads").call(#"{"retries":3}"#).decode()
}
print(settings) // ["retries": 3]
await librarySession.close()
```

### Stream output and limit execution time

```swift
let console = try await runtime.session()
let job = try await console.evaluate(
    """
    import asyncio
    print("Starting analysis")
    await asyncio.sleep(10)
    """,
    timeout: .seconds(1),
) { _, text in
    print(text, terminator: "")
}
print(job.end) // timedOut
await console.close()
```

Call `stop()` to interrupt an evaluation. Use `redirecting:` for file input
or to save logs alongside live output.

### Let the host approve Python file opens

Pass a `Python::Session.Delegate` to `runtime.session(delegate:)` to review
path-based file opens. Python raises `PermissionError` when the delegate declines
a request. [File access example](Tests/Python/SessionDelegateTests.swift)

### Expose Swift functions and classes to Python

```swift
@PythonModule("host")
enum Host {
    @PythonFunction
    static func label(_ name: String) async -> String {
        "Report for \(name)"
    }
}

@PythonClass(module: Host.self)
final class Counter {
    let context: Python::Context

    @PythonProperty var value: Int

    @PythonInit
    init(_ value: Int = 0, in context: Python::Context) throws {
        self.context = context
        try self.$value(value)
    }

    @PythonFunction
    func increment() throws {
        try self.$value { $0 + 1 }
    }
}

let hostSession = try await runtime.session(modules: [Host.self])
let report = try await hostSession.evaluate("""
import host

print(await host.label("April"))
counter = host.Counter(40)
counter.increment()
print(counter.value)
""")
print(report.output.stdout, terminator: "") // Report for April, then 41
await hostSession.close()
```

### Process Python buffers in place

Invert grayscale bytes in a Python buffer without copying it.

```swift
@PythonModule("buffers")
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

### Run a script with dependencies

Save this as `version_label.py`. The metadata block declares the script's Python
dependencies. [Inline script metadata (PEP 723)](https://packaging.python.org/en/latest/specifications/inline-script-metadata/)

```python
# /// script
# dependencies = ["packaging"]
# ///

import sys

from packaging.version import Version

print(Version(sys.argv[1]).public)
```

```swift
let scriptExecution = try await runtime.run(
    script: "/path/to/version_label.py",
    arguments: ["v2.1rc1+ci"],
)
print(scriptExecution.output.stdout, terminator: "") // 2.1rc1
```

Each run starts a fresh session and passes `arguments` through `sys.argv`.
Dependencies are resolved as pure-Python wheels. Pass `environmentDirectory:`
to reuse the installed set across runs.

### Open a Python project

Use a flat-layout project with an importable package such as `reporting/` beside
`pyproject.toml`. The session imports `reporting` and uses its globals.

```swift
let projectSession = try await runtime.session(
    .project(directory: "/path/to/project", module: "reporting"),
    environmentDirectory: "/path/to/environments/reporting",
)
print(try await projectSession.packages.installed())
await projectSession.close()
```

The session installs pure-Python dependencies from `requirements.txt` or
`pyproject.toml`. Use `session.packages` to inspect and manage them.

### Bundle a project for offline use

Build a ZIP containing the project's packages and startup module.

```swift
try await runtime.bundle(
    project: "/path/to/project",
    module: "reporting",
    to: "/path/to/reporting.zip",
)
```

Supply the ZIP as an application package source at runtime.

```swift
let bundledRuntime = try await Python::Runtime(
    packages: [.archive("/path/to/reporting.zip")],
)
let bundledSession = try await bundledRuntime.session(.module("reporting"))
await bundledSession.close()
```

To include the ZIP in a SwiftPM binary, add `.embedInCode("Resources/reporting.zip")`
to the target's resources and pass `.embedded(PackageResources.reporting_zip)`.
Use absolute paths for scripts, projects, environments, and archives.

## Requirements

- Swift 6.4 with SwiftPM's `experimentalCGen` support.
- macOS, iOS, and Mac Catalyst 26.4 or later. Apple builds require Xcode with the target SDK.
- Linux with glibc or musl, plus zlib and bzip2 development packages.
- GNU make and the host C/C++ toolchain in `/usr/bin`.

The manifest lists the SwiftPM traits for optional libraries and remote debugging.
[Package.swift](Package.swift)

## Credits

Thanks to the CPython contributors. [CPython](https://github.com/python/cpython)

Sources and licenses for bundled components are listed in [NOTICE](NOTICE).

## License

This package is available under the [MIT License](LICENSE).

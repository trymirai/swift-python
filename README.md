# swift-python

[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![iOS 26.4+](https://img.shields.io/badge/iOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Mac Catalyst 26.4+](https://img.shields.io/badge/Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)](#requirements)

Embed CPython 3.16.0a1 and its standard library in Swift with the static SwiftPM product `Python`.

## Installation

The examples use `main`. Add the package in `Package.swift`.

```swift
.package(url: "https://github.com/trymirai/swift-python.git", branch: "main")
```

Add the product to your target's dependencies.

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

let median = try await session.get("median_sample", as: Int.self)
print(execution.output.stdout, terminator: "") // 8
await session.close()
```

Sessions keep their globals between calls. `set` and `get` support Swift scalars, optionals, arrays,
and string-keyed dictionaries. Use `Python::Value` for dynamic values and `Python::Encodable` or
`Python::Decodable` for custom types.

The remaining examples reuse `runtime`.

### Call Python objects from Swift

```swift
let librarySession = try await runtime.session()
let settings: [String: Int] = try await librarySession.enqueue { context in
    let json = try context.import(module: "json")
    return try json.attribute("loads").call(#"{"retries":3}"#).decode()
}
await librarySession.close()
```

### Stream output and set a timeout

```swift
let console = try await runtime.session()
let job = try await console.evaluate(
    """
    import asyncio
    print("Starting")
    await asyncio.sleep(10)
    """,
    timeout: .seconds(1),
) { _, text in
    print(text, terminator: "")
}
print(job.end) // timedOut
await console.close()
```

Call `stop()` to interrupt an evaluation. Pass absolute paths in `redirecting:` to read stdin or
append stdout and stderr to files.

Startup runs on the first Python operation or explicitly through `initialize(redirecting:)`.
Read its captured output from `startupOutput`. [Stream examples](Tests/Python/StreamRedirectionTests.swift)

### Call Swift from Python

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

`MutableSpan` edits the Python buffer in place.
[Class exports](Tests/Python/Exports/ClassTests.swift) ·
[Async callbacks](Tests/Python/Exports/CallbackTests.swift)

## Scripts and projects

Use absolute paths.

### Run a script

Save as `version_label.py` with its [PEP 723 metadata](https://packaging.python.org/en/latest/specifications/inline-script-metadata/).

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

`run` passes `arguments` through `sys.argv` in a fresh session.

### Open a Python project

Put `reporting/` beside `pyproject.toml` or `requirements.txt`. The session imports `reporting`
on startup and uses its globals.

```swift
let projectSession = try await runtime.session(
    .project(directory: "/path/to/project", module: "reporting"),
    environmentDirectory: "/path/to/environments/reporting",
)
print(try await projectSession.get("__name__", as: String.self)) // reporting
await projectSession.close()
```

## Environments and dependencies

Project dependencies come from `requirements.txt` when present, otherwise from
`[project].dependencies` in `pyproject.toml`. Scripts use inline PEP 723 metadata.
The runtime prepares dependencies before Python starts. Local installs use compatible pure-Python
wheels from the index set by `Runtime(packageIndex:)` (PyPI by default).

Pass an absolute path as `environmentDirectory:` to `session` or `run` to keep local
installations and their saved resolution across runs. One session can use the directory at a time.
Omit it for temporary installs that are removed when the session closes. The runtime's
`cacheDirectory:` controls the separate cache for downloaded and unpacked wheels.

### Package precedence

For each distribution, the first source that provides it wins.

1. Local installations in the managed environment.
2. Sources passed to `session(packages:)`, in list order.
3. Sources passed to `Runtime(packages:)`, in list order.

Supply an existing `site-packages` directory as `.directory("/path/to/project/site-packages")`,
a ZIP file as `.archive(path)`, or ZIP bytes as `.embedded(bytes)`. Resolution fails when the
selected version conflicts with a project or script requirement, even if a later source has a
compatible version.

### Manage local dependencies

Use `session.packages` to inspect and change the environment.

- `installed()` lists the selected distribution versions, including supplied packages.
- `resolve()` re-reads project requirements and prefers compatible installed versions.
- `update()` re-resolves local packages using current versions from the index.
- `install(requirements:)` adds or replaces local requirements and can override a supplied version.
- `uninstall(_:)` removes local requirements or overrides. Removing an override brings back the
  supplied version if it satisfies the remaining requirements.

Once the interpreter has started, a change to the installed wheels returns `.requiresReset`.
Call `session.reset()` to clear Python state and invalidate its references, then retry the change.

### Bundle a project for offline use

```swift
try await runtime.bundle(
    project: "/path/to/project",
    module: "reporting",
    to: "/path/to/reporting.zip",
)

let bundledRuntime = try await Runtime(
    packages: [.archive("/path/to/reporting.zip")],
)
let bundledSession = try await bundledRuntime.session(.module("reporting"))
try await bundledSession.initialize()
await bundledSession.close()
```

To embed the ZIP, add `.embedInCode("Resources/reporting.zip")` to the SwiftPM target's resources
and pass `.embedded(PackageResources.reporting_zip)` as the package source.

## File access

Sessions allow reads from `directory:`, `importPaths:`, project roots, and package sources. Pass a
`Session.Delegate` with `shouldAllowFileAccess(_:)` for writes and other paths. Denied operations
raise `PermissionError`. Sessions restrict embedded native modules to an allowlist.

With `runtime.run(script:delegate:)`, the same delegate checks the script before it is read. Approval
covers that file. Pass `importPaths:` to grant reads from additional directories. When Swift supplies
a script path without a delegate, its directory is a read root.
[Delegate examples](Tests/Python/SessionDelegateTests.swift)

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

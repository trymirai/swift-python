# swift-python

[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![macOS 26.4+](https://img.shields.io/badge/macOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![iOS 26.4+](https://img.shields.io/badge/iOS-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Mac Catalyst 26.4+](https://img.shields.io/badge/Mac%20Catalyst-26.4%2B-315D8A?logo=apple&logoColor=white)](#requirements)
[![Linux with glibc and musl](https://img.shields.io/badge/Linux-glibc%20%26%20musl-316A54?logo=linux&logoColor=white)](#requirements)

Embed CPython 3.16.0a1 in a Swift application with Swift Package Manager. The
static `Python` library includes the interpreter and a selected standard
library, with its sources and resources embedded in the binary.

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

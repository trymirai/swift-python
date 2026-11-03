#ifdef SWIFT_PACKAGE
/* Initialization pulls in this object through the built-in module table. */
#if defined(__APPLE__)
#define SWIFT_PYTHON_LINK_LIBRARY(name) __asm__(".linker_option \"-l" name "\"");
#elif defined(__ELF__) && defined(__clang__)
#define SWIFT_PYTHON_LINK_PRAGMA(argument) _Pragma(#argument)
#define SWIFT_PYTHON_LINK_LIBRARY(name) SWIFT_PYTHON_LINK_PRAGMA(comment(lib, name))
#else
#define SWIFT_PYTHON_LINK_LIBRARY(name)
#endif

#ifndef SWIFT_PYTHON_BUNDLED_OPENSSL
SWIFT_PYTHON_LINK_LIBRARY("ssl")
SWIFT_PYTHON_LINK_LIBRARY("crypto")
#endif

#if !defined(SWIFT_PYTHON_BUNDLED_FFI) && !__has_include(<swift_python_default_libraries.h>)
SWIFT_PYTHON_LINK_LIBRARY("ffi")
#endif

#ifndef SWIFT_PYTHON_BUNDLED_MPDECIMAL
SWIFT_PYTHON_LINK_LIBRARY("mpdec")
#endif

#ifndef SWIFT_PYTHON_BUNDLED_LZMA
SWIFT_PYTHON_LINK_LIBRARY("lzma")
#endif

#ifndef SWIFT_PYTHON_BUNDLED_ZSTANDARD
SWIFT_PYTHON_LINK_LIBRARY("zstd")
#endif

#if !defined(SWIFT_PYTHON_BUNDLED_SQLITE) && !(defined(__linux__) && __has_include(<swift_python_default_libraries.h>))
SWIFT_PYTHON_LINK_LIBRARY("sqlite3")
#endif

#if defined(__linux__) && !defined(SWIFT_PYTHON_BUNDLED_READLINE)
SWIFT_PYTHON_LINK_LIBRARY("edit")
SWIFT_PYTHON_LINK_LIBRARY("panelw")
SWIFT_PYTHON_LINK_LIBRARY("ncursesw")
#endif

#undef SWIFT_PYTHON_LINK_LIBRARY
#undef SWIFT_PYTHON_LINK_PRAGMA
#endif /* SWIFT_PACKAGE */

#if defined(__linux__)
#include "../Generated/Builtins/linux.inc"
#elif defined(SWIFT_PYTHON_DESKTOP_MODULES)
#include "../Generated/Builtins/macos.inc"
#elif defined(SWIFT_PYTHON_PROCESS_MODULES)
#include "../Generated/Builtins/catalyst.inc"
#else
#include "../Generated/Builtins/ios.inc"
#endif

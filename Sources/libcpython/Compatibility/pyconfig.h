#ifndef SWIFT_PYTHON_LIBCPYTHON_PYCONFIG_H
#define SWIFT_PYTHON_LIBCPYTHON_PYCONFIG_H

#if defined(__APPLE__)
#include <TargetConditionals.h>

#if TARGET_OS_MACCATALYST
#if defined(__arm64__)
#include "Configuration/catalyst-arm64.h"
#elif defined(__x86_64__)
#include "Configuration/catalyst-x86_64.h"
#else
#error Unsupported Mac Catalyst architecture
#endif
#elif TARGET_OS_IOS && TARGET_OS_SIMULATOR
#if defined(__arm64__)
#include "Configuration/simulator-arm64.h"
#elif defined(__x86_64__)
#include "Configuration/simulator-x86_64.h"
#else
#error Unsupported iOS Simulator architecture
#endif
#elif TARGET_OS_IOS
#if defined(__arm64__)
#include "Configuration/ios-arm64.h"
#else
#error Unsupported iOS device architecture
#endif
#elif TARGET_OS_OSX
#if defined(__arm64__)
#include "Configuration/macos-arm64.h"
#elif defined(__x86_64__)
#include "Configuration/macos-x86_64.h"
#else
#error Unsupported macOS architecture
#endif
#if defined(HAVE_CURSES_IS_PAD)
// Use the SDK's opaque WINDOW and its is_pad accessor.
#undef WINDOW_HAS_FLAGS
#endif
#else
#error Unsupported Apple platform
#endif

#elif defined(__linux__)
/* Detect libc without importing system headers before private feature selection. */
#if __has_include(<gnu/libc-version.h>)
#define CPYTHON_GLIBC 1
#if defined(__aarch64__)
#include "Configuration/linux-gnu-arm64.h"
#elif defined(__x86_64__)
#include "Configuration/linux-gnu-x86_64.h"
#else
#error Unsupported Linux architecture
#endif
#else
#if defined(__aarch64__)
#include "Configuration/linux-musl-arm64.h"
#elif defined(__x86_64__)
#include "Configuration/linux-musl-x86_64.h"
#else
#error Unsupported Linux architecture
#endif
#endif
#else
#error Unsupported CPython platform
#endif

/* Upstream configure enables this by default. SwiftPM makes it opt-in. */
#ifndef SWIFT_PYTHON_REMOTE_DEBUGGING
#undef Py_REMOTE_DEBUG
#endif

#endif /* SWIFT_PYTHON_LIBCPYTHON_PYCONFIG_H */

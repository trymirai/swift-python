// Keep runtime ABI strings consistent with the generated sysconfig modules.
#ifndef SWIFT_PYTHON_LIBCPYTHON_ABI_H
#define SWIFT_PYTHON_LIBCPYTHON_ABI_H

#include "Python.h"

#define CPYTHON_ABI_PREFIX "cpython-" Py_STRINGIFY(PY_MAJOR_VERSION) Py_STRINGIFY(PY_MINOR_VERSION)

#if defined(__aarch64__) || defined(__arm64__)
#define CPYTHON_ARCH "arm64"
#define CPYTHON_LINUX_ARCH "aarch64"
#elif defined(__x86_64__)
#define CPYTHON_ARCH "x86_64"
#define CPYTHON_LINUX_ARCH "x86_64"
#else
#error Unsupported CPython architecture
#endif

#if defined(__linux__)
#define CPYTHON_PLATFORM "linux"
#if defined(CPYTHON_GLIBC)
#define CPYTHON_ABI "linux-gnu"
#else
#define CPYTHON_ABI "linux-musl"
#endif
#define CPYTHON_MULTIARCH CPYTHON_LINUX_ARCH "-" CPYTHON_ABI
#else
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#define CPYTHON_PLATFORM "darwin"
#define CPYTHON_ABI "darwin"
#elif TARGET_OS_MACCATALYST
#define CPYTHON_PLATFORM "ios"
#define CPYTHON_ABI "macabi"
#elif TARGET_OS_SIMULATOR
#define CPYTHON_PLATFORM "ios"
#define CPYTHON_ABI "iphonesimulator"
#else
#define CPYTHON_PLATFORM "ios"
#define CPYTHON_ABI "iphoneos"
#endif
#define CPYTHON_MULTIARCH CPYTHON_ARCH "-" CPYTHON_ABI
#endif

#ifdef SOABI_PLATFORM
#define CPYTHON_SOABI CPYTHON_ABI_PREFIX "-" SOABI_PLATFORM
#else
#define CPYTHON_SOABI CPYTHON_ABI_PREFIX "-" CPYTHON_MULTIARCH
#endif

#endif /* SWIFT_PYTHON_LIBCPYTHON_ABI_H */

#ifndef SWIFT_PYTHON_LIBFFI_FFICONFIG_H
#define SWIFT_PYTHON_LIBFFI_FFICONFIG_H

#if defined(__APPLE__)
#if defined(__aarch64__)
#include "../Generated/Configuration/apple-arm64.h"
#elif defined(__x86_64__)
#include "../Generated/Configuration/apple-x86_64.h"
#else
#error Unsupported libffi architecture
#endif
#elif defined(__linux__)
#if defined(__aarch64__)
#include "../Generated/Configuration/linux-arm64.h"
#elif defined(__x86_64__)
#include "../Generated/Configuration/linux-x86_64.h"
#else
#error Unsupported libffi architecture
#endif
#else
#error Unsupported libffi platform
#endif

#endif /* SWIFT_PYTHON_LIBFFI_FFICONFIG_H */

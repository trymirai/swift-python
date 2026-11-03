#ifndef SWIFT_PYTHON_LIBFFI_FFI_H
#define SWIFT_PYTHON_LIBFFI_FFI_H

#if defined(__APPLE__) && defined(__aarch64__)
#define FFI_EXEC_TRAMPOLINE_TABLE 1
#else
#define FFI_EXEC_TRAMPOLINE_TABLE 0
#endif

#if defined(__x86_64__) && (defined(__APPLE__) || defined(__linux__))
#include "Configuration/x86_64.h"
#elif defined(__aarch64__) && defined(__APPLE__)
#include "Configuration/apple-arm64.h"
#elif defined(__aarch64__) && defined(__linux__)
#include "Configuration/linux-arm64.h"
#elif defined(__APPLE__) || defined(__linux__)
#error Unsupported libffi architecture
#else
#error Unsupported libffi platform
#endif

#endif /* SWIFT_PYTHON_LIBFFI_FFI_H */

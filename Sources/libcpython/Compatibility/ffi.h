#ifndef SWIFT_PYTHON_LIBCPYTHON_FFI_H
#define SWIFT_PYTHON_LIBCPYTHON_FFI_H

/* Prefer the provider's include path. Apple SDKs nest their header under ffi/. */
#if __has_include_next(<ffi.h>)
#include_next <ffi.h>
#elif __has_include(<ffi/ffi.h>)
#include <ffi/ffi.h>
#else
#error "libffi headers are required. Enable the FFI trait or supply headers for the target."
#endif

/* Match CPython's configure flags when compiling against Apple's libffi. */
#if defined(FFI_AVAILABLE_APPLE) && !defined(USING_APPLE_OS_LIBFFI)
#define USING_APPLE_OS_LIBFFI 1
#endif

#endif /* SWIFT_PYTHON_LIBCPYTHON_FFI_H */

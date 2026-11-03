#ifndef SWIFT_PYTHON_LIBFFI_FFITARGET_H
#define SWIFT_PYTHON_LIBFFI_FFITARGET_H

#if defined(__aarch64__)
#include "../src/aarch64/ffitarget.h"
#elif defined(__x86_64__)
#include "../src/x86/ffitarget.h"
#else
#error Unsupported libffi architecture
#endif

#endif /* SWIFT_PYTHON_LIBFFI_FFITARGET_H */

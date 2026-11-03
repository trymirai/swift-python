#ifndef SWIFT_PYTHON_LIBCPYTHON_KRML_INTERNAL_TARGET_H
#define SWIFT_PYTHON_LIBCPYTHON_KRML_INTERNAL_TARGET_H

#ifdef __APPLE__
#include <TargetConditionals.h>
#include <AvailabilityMacros.h>

/* KaRaMeL's legacy-macOS test also matches the zero macOS deployment value
 * used by iOS and Catalyst. Keep that test local to actual macOS; all supported
 * deployment targets provide aligned_alloc. Leave the upstream checkout intact.
 */
#if defined(__APPLE__) && !TARGET_OS_OSX
#pragma push_macro("MAC_OS_X_VERSION_MIN_REQUIRED")
#undef MAC_OS_X_VERSION_MIN_REQUIRED
#endif
#endif /* __APPLE__ */

#include "../../../src/Modules/_hacl/include/krml/internal/target.h"

#if defined(__APPLE__) && !TARGET_OS_OSX
#pragma pop_macro("MAC_OS_X_VERSION_MIN_REQUIRED")
#endif

#endif /* SWIFT_PYTHON_LIBCPYTHON_KRML_INTERNAL_TARGET_H */

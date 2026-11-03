#ifndef SWIFT_PYTHON_LIBCPYTHON_EMBEDDED_H
#define SWIFT_PYTHON_LIBCPYTHON_EMBEDDED_H

#include "Python.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Serialize initialization and finalization in the caller. Pass an initialized PyConfig.
 * The caller owns the configuration and any interpreter left initialized on return.
 * Include embedded:/stdlib in explicit search paths to load the embedded library. */
PyStatus CPython_Initialize(PyConfig *config);

/* Install in the current interpreter with an attached thread state.
 * Returns -1 with a Python exception on failure. */
int CPython_InstallEmbeddedImporter(void);

#ifdef __cplusplus
}
#endif

#endif /* SWIFT_PYTHON_LIBCPYTHON_EMBEDDED_H */

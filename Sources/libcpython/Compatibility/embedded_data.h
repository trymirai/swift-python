#ifndef SWIFT_PYTHON_LIBCPYTHON_EMBEDDED_DATA_H
#define SWIFT_PYTHON_LIBCPYTHON_EMBEDDED_DATA_H

#include <stddef.h>

struct _frozen;
extern const struct _frozen *const CPythonEmbeddedFrozenModules;

// Names and paths are UTF-8; catalogs are sorted by name/path with strcmp ordering.
typedef struct {
    const char *name;
    const char *path;
    int is_package;
} CPythonEmbeddedModule;

typedef struct {
    const char *path;
    // Borrowed read-only bytes with process lifetime; Python reads make interpreter-owned copies.
    const unsigned char *bytes;
    size_t size;
} CPythonEmbeddedResource;

extern const CPythonEmbeddedModule CPythonEmbeddedModules[];
extern const size_t CPythonEmbeddedModuleCount;
extern const CPythonEmbeddedResource CPythonEmbeddedResources[];
extern const size_t CPythonEmbeddedResourceCount;

#endif /* SWIFT_PYTHON_LIBCPYTHON_EMBEDDED_DATA_H */

#ifndef SWIFT_PYTHON_LIBCPYTHON_FILE_OPEN_H
#define SWIFT_PYTHON_LIBCPYTHON_FILE_OPEN_H

#include "Python.h"

/* The caller frees any replacement path with PyMem_Free(). */
int CPython_CheckFileOpen(const char *path, int dir_fd, int flags, PyObject *filename,
                          char **replacement);

#endif /* SWIFT_PYTHON_LIBCPYTHON_FILE_OPEN_H */

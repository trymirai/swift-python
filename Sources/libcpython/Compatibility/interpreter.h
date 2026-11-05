#ifndef SWIFT_PYTHON_LIBCPYTHON_INTERPRETER_H
#define SWIFT_PYTHON_LIBCPYTHON_INTERPRETER_H

#include "Python.h"
#include <stdbool.h>
#include <stdint.h>

PyStatus CPython_InitializeRuntime(void);

PyStatus CPython_NewThreadState(PyThreadState *_Nullable *_Nonnull state);
void CPython_EndThreadState(PyThreadState *_Nonnull state);

PyObject *_Nullable CPython_Call3(PyObject *_Nonnull function, PyObject *_Nonnull first,
                                  PyObject *_Nonnull second, PyObject *_Nonnull third);
PyObject *_Nullable CPython_Evaluate(PyObject *_Nonnull function, PyObject *_Nonnull source,
                                     PyObject *_Nonnull filename, PyObject *_Nonnull control,
                                     void *_Nullable context,
                                     bool (*_Nonnull interrupt)(void *_Nullable context));

typedef enum {
    CPython_ValueNone,
    CPython_ValueBool,
    CPython_ValueInteger,
    CPython_ValueFloat,
    CPython_ValueString,
    CPython_ValueBytes,
    CPython_ValueSequence,
    CPython_ValueDictionary,
    CPython_ValueUnsupported,
} CPython_ValueType;

CPython_ValueType CPython_ValueTypeOf(PyObject *_Nonnull object);
PyObject *_Nullable CPython_NewFunction(
    void *_Nullable context,
    PyObject *_Nullable (*_Nonnull call)(void *_Nullable context, PyObject *_Nullable arguments),
    void (*_Nonnull destroy)(void *_Nullable context));
void CPython_RaiseSwiftError(const char *_Nonnull name, const char *_Nonnull message);
int CPython_IsKeyError(void);
uintptr_t CPython_InterpreterKey(PyThreadState *_Nullable state);
const char *_Nonnull CPython_ExceptionName(PyObject *_Nonnull exception);
PyObject *_Nullable CPython_NewPeer(void *_Nonnull value, void (*_Nonnull destroy)(void *_Nonnull));
void *_Nullable CPython_GetPeer(PyObject *_Nonnull capsule);
PyObject *_Nullable CPython_NewWeakReference(PyObject *_Nonnull object);
PyObject *_Nullable CPython_ResolveWeakReference(PyObject *_Nonnull reference);
int CPython_FreezeType(PyObject *_Nonnull type);
int CPython_BufferIsSupported(PyObject *_Nonnull object, int writable,
                              PyObject *_Nonnull array_type);

typedef void (*CPython_ExportConsumer)(void *_Nonnull collector, const void *_Nonnull record);
typedef void (*CPython_ExportRegistration)(void *_Nonnull collector,
                                           CPython_ExportConsumer _Nonnull consume);
void CPython_RegisterExport(CPython_ExportRegistration _Nonnull registration);
void CPython_DiscoverExports(void *_Nonnull collector, CPython_ExportConsumer _Nonnull consume);

int CPython_NewPipe(int *_Nonnull reader, int *_Nonnull writer);

#endif /* SWIFT_PYTHON_LIBCPYTHON_INTERPRETER_H */

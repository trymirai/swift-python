#ifndef SWIFT_PYTHON_LIBCPYTHON_INTERPRETER_H
#define SWIFT_PYTHON_LIBCPYTHON_INTERPRETER_H

#include "Python.h"
#include "file_open.h"
#include <stdbool.h>
#include <stdint.h>

PyStatus CPython_InitializeRuntime(void);

typedef struct CPython_Heap CPython_Heap;

// Create a detached interpreter. Request a heap to track its allocations for checkpoints.
PyStatus CPython_NewThreadState(PyThreadState *_Nullable *_Nonnull state,
                                CPython_Heap *_Nullable *_Nullable heap);
void CPython_EndThreadState(PyThreadState *_Nonnull state, CPython_Heap *_Nullable heap);
void CPython_AttachThreadState(PyThreadState *_Nonnull state, CPython_Heap *_Nullable heap);
void CPython_DetachThreadState(void);
PyInterpreterView *_Nullable CPython_NewInterpreterView(PyThreadState *_Nonnull state);
uintptr_t CPython_InterpreterKey(PyThreadState *_Nullable state);

CPython_Heap *_Nullable CPython_BindHeap(CPython_Heap *_Nullable heap);
void *_Nullable CPython_SetScope(void *_Nullable scope);
void *_Nullable CPython_CurrentScope(void);

int CPython_BeginCheckpoint(void);
void CPython_FinishCheckpoint(bool restoring);

PyObject *_Nullable CPython_Call3(PyObject *_Nonnull function, PyObject *_Nonnull first,
                                  PyObject *_Nonnull second, PyObject *_Nonnull third);

// Takes ownership of context even if creating the function fails.
PyObject *_Nullable CPython_NewFunction(
    void *_Nullable context,
    PyObject *_Nullable (*_Nonnull call)(void *_Nullable context, PyObject *_Nullable arguments),
    void (*_Nonnull destroy)(void *_Nullable context));

PyObject *_Nullable CPython_CallInterruptibly(PyObject *_Nonnull function,
                                              PyObject *_Nonnull const *_Nullable arguments,
                                              size_t argument_count, void *_Nullable context,
                                              bool (*_Nonnull interrupt)(void *_Nullable context));

typedef struct {
    void *_Nullable context;
    bool (*_Nonnull interrupt)(void *_Nullable context);
} CPython_Evaluation;

CPython_Evaluation *_Nullable CPython_SetEvaluation(CPython_Evaluation *_Nullable evaluation);
void CPython_InterruptThreadState(PyThreadState *_Nonnull state);
bool CPython_TakeThreadInterruption(void);
void CPython_RequestEvaluationInterrupt(PyInterpreterState *_Nonnull interpreter);

void CPython_RaiseSwiftError(const char *_Nonnull name, const char *_Nonnull message);
void CPython_RaiseKeyboardInterrupt(void);
int CPython_IsKeyError(void);
const char *_Nonnull CPython_ExceptionName(PyObject *_Nonnull exception);

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
bool CPython_IsList(PyObject *_Nonnull object);

int CPython_BufferIsSupported(PyObject *_Nonnull object, int writable,
                              PyObject *_Nonnull array_type);

// Takes ownership of value even if creating the capsule fails.
PyObject *_Nullable CPython_NewPeer(void *_Nonnull value, void (*_Nonnull destroy)(void *_Nonnull));
void *_Nullable CPython_GetPeer(PyObject *_Nonnull capsule);
int CPython_FreezeType(PyObject *_Nonnull type);

PyObject *_Nullable CPython_NewWeakReference(PyObject *_Nonnull object);
PyObject *_Nullable CPython_ResolveWeakReference(PyObject *_Nonnull reference);

typedef void (*CPython_ExportConsumer)(void *_Nonnull collector, const void *_Nonnull record);
typedef void (*CPython_ExportRegistration)(void *_Nonnull collector,
                                           CPython_ExportConsumer _Nonnull consume);
void CPython_RegisterExport(CPython_ExportRegistration _Nonnull registration);
void CPython_DiscoverExports(void *_Nonnull collector, CPython_ExportConsumer _Nonnull consume);

int CPython_NewPipe(int *_Nonnull reader, int *_Nonnull writer);
int CPython_WaitForCall(int reply_fd, int interruption_fd);

#endif /* SWIFT_PYTHON_LIBCPYTHON_INTERPRETER_H */

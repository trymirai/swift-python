#ifndef SWIFT_PYTHON_CHECKPOINT_H
#define SWIFT_PYTHON_CHECKPOINT_H

#include "Python.h"
#include <stdbool.h>

typedef struct CPython_Heap CPython_Heap;

int CPython_InstallHeapTracking(void);
CPython_Heap *CPython_NewHeap(void);
void CPython_FreeHeap(CPython_Heap *heap);
void CPython_BindHeap(CPython_Heap *heap);

// The interpreter's thread state must be attached and its heap bound on this thread.
int CPython_BeginHeapCheckpoint(PyThreadState *state);
void CPython_FinishHeapCheckpoint(PyThreadState *state, bool restoring);

#endif

#ifndef SWIFT_PYTHON_LIBCPYTHON_THREAD_H
#define SWIFT_PYTHON_LIBCPYTHON_THREAD_H

#include <stdbool.h>

typedef struct CPython_ThreadEvent CPython_ThreadEvent;

CPython_ThreadEvent *CPython_ThreadEvent_New(void);
void CPython_ThreadEvent_Free(CPython_ThreadEvent *event);

void CPython_ThreadEvent_Bind(CPython_ThreadEvent *event);
bool CPython_ThreadEvent_IsCurrent(const CPython_ThreadEvent *event);

void CPython_ThreadEvent_Signal(CPython_ThreadEvent *event);
void CPython_ThreadEvent_Wait(CPython_ThreadEvent *event);

int CPython_StartThread(void *(*entry)(void *), void *context);

#endif /* SWIFT_PYTHON_LIBCPYTHON_THREAD_H */

#include "../interpreter.h"

// Asyncio restores each handle's captured context. Cache access for native I/O
// that checks it with the GIL released.
static _Thread_local CPython_OperationContext *current;

static int
context_switched(PyContextEvent event, PyObject *context)
{
    if (current == NULL || event != Py_CONTEXT_SWITCHED) {
        return 0;
    }

    PyObject *value = NULL;
    current->active = false;
    if (context != Py_None && PyContextVar_Get(current->marker, NULL, &value) < 0) {
        return -1;
    }

    current->active = value == Py_True;
    Py_XDECREF(value);
    CPython_ResumeDeferredInterruption();
    return 0;
}

int
CPython_WatchOperationContexts(void)
{
    return PyContext_AddWatcher(context_switched) < 0 ? -1 : 0;
}

int
CPython_EnterOperationContext(CPython_OperationContext *context, PyObject *marker)
{
    context->marker = marker != NULL ? Py_NewRef(marker)
                                     : PyContextVar_New("swift-python.operation", NULL);
    if (context->marker == NULL) {
        return -1;
    }

    context->token = PyContextVar_Set(context->marker, Py_True);
    if (context->token == NULL) {
        Py_CLEAR(context->marker);
        return -1;
    }

    context->previous = current;
    context->active = true;
    current = context;
    return 0;
}

void
CPython_LeaveOperationContext(CPython_OperationContext *context)
{
    current = context->previous;

    if (PyContextVar_Reset(context->marker, context->token) < 0) {
        PyErr_FormatUnraisable("while leaving a Swift Python operation");
    }
    Py_CLEAR(context->token);
    Py_CLEAR(context->marker);
}

bool
CPython_HasOperationAccess(void)
{
    return current == NULL || current->active;
}

int
CPython_ContextBelongsToOperation(PyObject *context)
{
    return current == NULL ? 0 : PyMapping_HasKeyWithError(context, current->marker);
}

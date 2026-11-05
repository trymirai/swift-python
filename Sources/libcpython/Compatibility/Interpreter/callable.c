#include "../interpreter.h"

#include <pthread.h>
#include <stdlib.h>

typedef struct {
    pthread_t thread;
    void *context;
    PyObject *(*call)(void *context, PyObject *arguments);
    void (*destroy)(void *context);
} SwiftFunction;

static const char capsule_name[] = "swift-python.function";

static void
destroy_function(PyObject *capsule)
{
    SwiftFunction *function = PyCapsule_GetPointer(capsule, capsule_name);
    if (function != NULL) {
        function->destroy(function->context);
        free(function);
    }
}

static PyObject *
call_function(PyObject *capsule, PyObject *arguments)
{
    SwiftFunction *function = PyCapsule_GetPointer(capsule, capsule_name);
    if (function == NULL) {
        return NULL;
    }
    if (!pthread_equal(function->thread, pthread_self())) {
        PyErr_SetString(PyExc_RuntimeError, "A Swift callback must run on its interpreter thread.");
        return NULL;
    }
    return function->call(function->context, arguments);
}

static PyMethodDef method = {
    .ml_name = "_swift_call",
    .ml_meth = call_function,
    .ml_flags = METH_VARARGS,
};

PyObject *
CPython_NewFunction(void *context, PyObject *(*call)(void *context, PyObject *arguments),
                    void (*destroy)(void *context))
{
    SwiftFunction *function = malloc(sizeof(*function));
    if (function == NULL) {
        destroy(context);
        return PyErr_NoMemory();
    }
    *function = (SwiftFunction){pthread_self(), context, call, destroy};
    PyObject *capsule = PyCapsule_New(function, capsule_name, destroy_function);
    if (capsule == NULL) {
        destroy(context);
        free(function);
        return NULL;
    }
    PyObject *result = PyCFunction_NewEx(&method, capsule, NULL);
    Py_DECREF(capsule);
    return result;
}

PyObject *
CPython_Call3(PyObject *function, PyObject *first, PyObject *second, PyObject *third)
{
    PyObject *arguments[] = {first, second, third};
    return PyObject_Vectorcall(function, arguments, 3, NULL);
}

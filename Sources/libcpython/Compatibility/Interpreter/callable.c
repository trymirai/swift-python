#include "../interpreter.h"

#include <stdlib.h>

typedef struct {
    uintptr_t interpreter;

    void *context;
    PyObject *(*call)(void *context, PyObject *arguments);
    void (*destroy)(void *context);
} SwiftFunction;

static const char capsule_name[] = "swift-python.function";

static void
free_function(SwiftFunction *function)
{
    function->destroy(function->context);
    free(function);
}

static void
destroy_capsule(PyObject *capsule)
{
    SwiftFunction *function = PyCapsule_GetPointer(capsule, capsule_name);
    if (function != NULL) {
        free_function(function);
    }
}

static PyObject *
call_function(PyObject *capsule, PyObject *arguments)
{
    SwiftFunction *function = PyCapsule_GetPointer(capsule, capsule_name);
    if (function == NULL) {
        return NULL;
    }

    if (function->interpreter != CPython_InterpreterKey(NULL)) {
        PyErr_SetString(PyExc_RuntimeError, "A Swift callback belongs to another interpreter.");
        return NULL;
    }

    return function->call(function->context, arguments);
}

static PyMethodDef function_method = {
    .ml_name = "_swift_call",
    .ml_meth = call_function,
    .ml_flags = METH_VARARGS,
};

PyObject *
CPython_NewFunction(void *context, PyObject *(*call)(void *context, PyObject *arguments),
                    void (*destroy)(void *context))
{
    // The Swift caller transfers ownership before any allocation.
    SwiftFunction *function = malloc(sizeof(*function));
    if (function == NULL) {
        destroy(context);
        return PyErr_NoMemory();
    }

    *function = (SwiftFunction){
        .interpreter = CPython_InterpreterKey(NULL),

        .context = context,
        .call = call,
        .destroy = destroy,
    };

    PyObject *capsule = PyCapsule_New(function, capsule_name, destroy_capsule);
    if (capsule == NULL) {
        free_function(function);
        return NULL;
    }

    PyObject *callable = PyCFunction_NewEx(&function_method, capsule, NULL);
    // The callable retains the capsule on success. On failure this releases the Swift context.
    Py_DECREF(capsule);
    return callable;
}

PyObject *
CPython_Call3(PyObject *function, PyObject *first, PyObject *second, PyObject *third)
{
    PyObject *arguments[] = {first, second, third};
    return PyObject_Vectorcall(function, arguments, 3, NULL);
}

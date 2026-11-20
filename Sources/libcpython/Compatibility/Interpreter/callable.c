#include "../interpreter.h"

#include <stdlib.h>

typedef PyObject *(*SwiftFunctionCall)(void *context, PyObject *arguments);
typedef void (*SwiftFunctionDestroy)(void *context);

typedef struct {
    uintptr_t interpreter;

    void *context;

    SwiftFunctionCall call;
    SwiftFunctionDestroy destroy;
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

static PyObject *
new_function_capsule(void *context, SwiftFunctionCall call, SwiftFunctionDestroy destroy)
{
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
    }
    return capsule;
}

PyObject *
CPython_NewFunction(void *context, SwiftFunctionCall call, SwiftFunctionDestroy destroy)
{
    PyObject *capsule = new_function_capsule(context, call, destroy);
    if (capsule == NULL) {
        return NULL;
    }

    PyObject *callable = PyCFunction_NewEx(&function_method, capsule, NULL);
    // On success the callable keeps its own reference to the capsule.
    Py_DECREF(capsule);
    return callable;
}

PyObject *
CPython_Call2(PyObject *function, PyObject *first, PyObject *second)
{
    PyObject *arguments[] = {first, second};
    return PyObject_Vectorcall(function, arguments, 2, NULL);
}

PyObject *
CPython_Call3(PyObject *function, PyObject *first, PyObject *second, PyObject *third)
{
    PyObject *arguments[] = {first, second, third};
    return PyObject_Vectorcall(function, arguments, 3, NULL);
}

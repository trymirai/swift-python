#include "../interpreter.h"

static PyObject *
builtin_exception_type(const char *name)
{
    PyObject *type = PyDict_GetItemString(PyEval_GetBuiltins(), name);
    // A Swift error must not act as a Python control-flow exception.
    if (type == NULL || !PyExceptionClass_Check(type) ||
        PyObject_IsSubclass(type, PyExc_Exception) != 1) {
        PyErr_Clear();
        return PyExc_RuntimeError;
    }
    return type;
}

void
CPython_RaiseSwiftError(const char *name, const char *message, Py_ssize_t size)
{
    PyObject *type = builtin_exception_type(name);
    PyObject *text = PyUnicode_FromStringAndSize(message, size);
    if (text == NULL) {
        return;
    }

    PyErr_SetObject(type, text);
    Py_DECREF(text);
}

int
CPython_IsKeyError(void)
{
    return PyErr_ExceptionMatches(PyExc_KeyError);
}

void
CPython_RaiseKeyboardInterrupt(void)
{
    PyErr_SetNone(PyExc_KeyboardInterrupt);
}

PyObject *
CPython_ExceptionName(PyObject *exception)
{
    return PyType_GetName(Py_TYPE(exception));
}

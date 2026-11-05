#include "../interpreter.h"

void
CPython_RaiseSwiftError(const char *name, const char *message)
{
    PyObject *type = PyDict_GetItemString(PyEval_GetBuiltins(), name);
    if (type == NULL || !PyExceptionClass_Check(type) ||
        PyObject_IsSubclass(type, PyExc_Exception) != 1) {
        PyErr_Clear();
        type = PyExc_RuntimeError;
    }
    PyErr_SetString(type, message);
}

int
CPython_IsKeyError(void)
{
    return PyErr_ExceptionMatches(PyExc_KeyError);
}

const char *
CPython_ExceptionName(PyObject *exception)
{
    return Py_TYPE(exception)->tp_name;
}

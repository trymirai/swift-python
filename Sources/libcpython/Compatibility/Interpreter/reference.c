#include "../interpreter.h"

PyObject *
CPython_NewWeakReference(PyObject *object)
{
    return PyWeakref_NewRef(object, NULL);
}

PyObject *
CPython_ResolveWeakReference(PyObject *reference)
{
    PyObject *object = NULL;
    int status = PyWeakref_GetRef(reference, &object);
    if (status < 0) {
        return NULL;
    }
    return status == 0 ? Py_NewRef(Py_None) : object;
}

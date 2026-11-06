#include "../interpreter.h"

bool
CPython_IsList(PyObject *object)
{
    return PyList_CheckExact(object);
}

CPython_ValueType
CPython_ValueTypeOf(PyObject *object)
{
    if (Py_IsNone(object)) {
        return CPython_ValueNone;
    }

    if (PyBool_Check(object)) {
        return CPython_ValueBool;
    }
    if (PyLong_CheckExact(object)) {
        return CPython_ValueInteger;
    }
    if (PyFloat_CheckExact(object)) {
        return CPython_ValueFloat;
    }

    if (PyUnicode_CheckExact(object)) {
        return CPython_ValueString;
    }
    if (PyBytes_CheckExact(object)) {
        return CPython_ValueBytes;
    }

    if (CPython_IsList(object) || PyTuple_CheckExact(object)) {
        return CPython_ValueSequence;
    }
    if (PyDict_CheckExact(object)) {
        return CPython_ValueDictionary;
    }
    return CPython_ValueUnsupported;
}

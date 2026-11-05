#include "../interpreter.h"

int
CPython_BufferIsSupported(PyObject *object, int writable, PyObject *array_type)
{
    while (PyMemoryView_Check(object)) {
        object = PyMemoryView_GET_BASE(object);
        if (object == NULL) {
            return 0;
        }
    }
    return (!writable && PyBytes_CheckExact(object))
        || PyByteArray_CheckExact(object)
        || (PyObject *)Py_TYPE(object) == array_type;
}

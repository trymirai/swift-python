#include "Python.h"
#include "embedded_data.h"
#include "internal/pycore_unicodeobject.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static int
compare_module_name(const void *key, const void *item)
{
    const CPythonEmbeddedModule *module = item;
    return strcmp(key, module->name);
}

static PyObject *
lookup_module(PyObject *Py_UNUSED(self), PyObject *argument)
{
    const char *name = _PyUnicode_AsUTF8NoNUL(argument);
    if (name == NULL) {
        return NULL;
    }

    const CPythonEmbeddedModule *module =
        bsearch(name, CPythonEmbeddedModules, CPythonEmbeddedModuleCount,
                sizeof(CPythonEmbeddedModules[0]), compare_module_name);
    if (module == NULL) {
        Py_RETURN_NONE;
    }
    return Py_BuildValue("(si)", module->path, module->is_package);
}

static int
compare_resource_path(const void *key, const void *item)
{
    const CPythonEmbeddedResource *resource = item;
    return strcmp(key, resource->path);
}

static const CPythonEmbeddedResource *
find_resource(const char *path)
{
    return bsearch(path, CPythonEmbeddedResources, CPythonEmbeddedResourceCount,
                   sizeof(CPythonEmbeddedResources[0]), compare_resource_path);
}

static PyObject *
read_resource(PyObject *Py_UNUSED(self), PyObject *argument)
{
    const char *path = _PyUnicode_AsUTF8NoNUL(argument);
    if (path == NULL) {
        return NULL;
    }

    const CPythonEmbeddedResource *entry = find_resource(path);
    if (entry == NULL) {
        PyErr_SetObject(PyExc_FileNotFoundError, argument);
        return NULL;
    }
    return PyBytes_FromStringAndSize((const char *)entry->bytes, (Py_ssize_t)entry->size);
}

static PyObject *
is_resource_file(PyObject *Py_UNUSED(self), PyObject *argument)
{
    const char *path = _PyUnicode_AsUTF8NoNUL(argument);
    if (path == NULL) {
        return NULL;
    }
    return PyBool_FromLong(find_resource(path) != NULL);
}

// Include the separator so a sibling with the same prefix falls outside the directory range.
static int
compare_directory(const char *entry, const char *path, size_t length)
{
    if (length == 0) {
        return 0;
    }
    int order = strncmp(entry, path, length);
    return order == 0 ? (unsigned char)entry[length] - '/' : order;
}

static size_t
directory_lower_bound(const char *path, size_t length)
{
    size_t lower = 0;
    size_t upper = CPythonEmbeddedResourceCount;
    while (lower < upper) {
        size_t middle = lower + (upper - lower) / 2;
        if (compare_directory(CPythonEmbeddedResources[middle].path, path, length) < 0) {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    return lower;
}

static bool
resource_is_in_directory(size_t index, const char *path, size_t length)
{
    return index < CPythonEmbeddedResourceCount &&
           compare_directory(CPythonEmbeddedResources[index].path, path, length) == 0;
}

static PyObject *
is_resource_directory(PyObject *Py_UNUSED(self), PyObject *argument)
{
    const char *path = _PyUnicode_AsUTF8NoNUL(argument);
    if (path == NULL) {
        return NULL;
    }

    size_t length = strlen(path);
    size_t index = directory_lower_bound(path, length);
    return PyBool_FromLong(resource_is_in_directory(index, path, length));
}

static int
append_resource_name(PyObject *children, const char *child, size_t size)
{
    PyObject *name = PyUnicode_FromStringAndSize(child, (Py_ssize_t)size);
    if (name == NULL) {
        return -1;
    }
    int status = PyList_Append(children, name);
    Py_DECREF(name);
    return status;
}

static int
append_directory_children(PyObject *children, const char *path)
{
    size_t length = strlen(path);
    size_t prefix = length + (length != 0);

    const char *last = NULL;
    size_t last_size = 0;
    for (size_t index = directory_lower_bound(path, length);
         resource_is_in_directory(index, path, length); index++) {
        const char *child = CPythonEmbeddedResources[index].path + prefix;
        const char *slash = strchr(child, '/');
        size_t size = slash == NULL ? strlen(child) : (size_t)(slash - child);

        // Sorted paths place all descendants of a directory next to one another.
        if (last != NULL && size == last_size && strncmp(last, child, size) == 0) {
            continue;
        }
        if (append_resource_name(children, child, size) < 0) {
            return -1;
        }
        last = child;
        last_size = size;
    }
    return 0;
}

static PyObject *
list_resource_children(PyObject *Py_UNUSED(self), PyObject *argument)
{
    const char *path = _PyUnicode_AsUTF8NoNUL(argument);
    if (path == NULL) {
        return NULL;
    }

    PyObject *result = PyList_New(0);
    if (result == NULL) {
        return NULL;
    }
    if (append_directory_children(result, path) < 0) {
        Py_DECREF(result);
        return NULL;
    }
    return result;
}

static PyMethodDef embedded_methods[] = {
    {"read", read_resource, METH_O, "Read one embedded resource."},
    {"module", lookup_module, METH_O, "Find an embedded Python module."},
    {"children", list_resource_children, METH_O, "List immediate resource children."},
    {"is_directory", is_resource_directory, METH_O, NULL},
    {"is_file", is_resource_file, METH_O, NULL},
    {NULL, NULL, 0, NULL},
};

static PyModuleDef_Slot embedded_slots[] = {
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
    {0, NULL},
};

static struct PyModuleDef embedded_module = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_swift_python",
    .m_doc = "Read-only data embedded by swift-python.",
    .m_size = 0,
    .m_methods = embedded_methods,
    .m_slots = embedded_slots,
};

PyMODINIT_FUNC
PyInit__swift_python(void)
{
    return PyModuleDef_Init(&embedded_module);
}

#include "embedded.h"
#include "embedded_data.h"

static const wchar_t embedded_stdlib_path[] = L"embedded:/stdlib";

int
CPython_InstallEmbeddedImporter(void)
{
    PyObject *module = PyImport_ImportModule("_swift_python_importer");
    if (module == NULL) {
        return -1;
    }
    Py_DECREF(module);
    return 0;
}

static PyStatus
configure_embedded_paths(PyConfig *config)
{
    if (config->stdlib_dir == NULL) {
        PyStatus status = PyConfig_SetString(config, &config->stdlib_dir, embedded_stdlib_path);
        if (PyStatus_Exception(status)) {
            return status;
        }
    }

    if (!config->module_search_paths_set) {
        PyStatus status = PyWideStringList_Append(&config->module_search_paths, embedded_stdlib_path);
        if (PyStatus_Exception(status)) {
            return status;
        }
        config->module_search_paths_set = 1;
    }
    return PyStatus_Ok();
}

PyStatus
CPython_Initialize(PyConfig *config)
{
    if (config == NULL) {
        return PyStatus_Error("Missing embedded Python configuration");
    }
    if (Py_IsInitialized()) {
        return PyStatus_Error("Python is already initialized");
    }

    PyStatus status = configure_embedded_paths(config);
    if (PyStatus_Exception(status)) {
        return status;
    }

    PyImport_FrozenModules = CPythonEmbeddedFrozenModules;
    status = Py_InitializeFromConfig(config);
    if (PyStatus_Exception(status)) {
        return status;
    }

    if (CPython_InstallEmbeddedImporter() < 0) {
        return PyStatus_Error("Cannot install the embedded standard-library importer");
    }
    return status;
}

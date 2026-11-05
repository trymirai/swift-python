#include "../embedded.h"
#include "../interpreter.h"

PyStatus
CPython_InitializeRuntime(void)
{
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.site_import = 0;
    config.write_bytecode = 0;
    PyStatus status = CPython_Initialize(&config);
    PyConfig_Clear(&config);
    if (PyThreadState_GetUnchecked() != NULL) {
        PyEval_SaveThread();
    }
    return status;
}

PyStatus
CPython_NewThreadState(PyThreadState **state)
{
    *state = NULL;
    PyThreadState *bootstrap = PyThreadState_New(PyInterpreterState_Main());
    if (bootstrap == NULL) {
        return PyStatus_NoMemory();
    }

    PyInterpreterConfig config = {
        .use_main_obmalloc = 0,
        .allow_fork = 0,
        .allow_exec = 0,
        .allow_threads = 0,
        .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 1,
        .gil = PyInterpreterConfig_OWN_GIL,
    };
    PyEval_RestoreThread(bootstrap);
    PyStatus status = Py_NewInterpreterFromConfig(state, &config);

    /* Creation switches to the new GIL. Detach it before freeing the main
       interpreter's temporary state, which is bound to this same thread. */
    if (*state != NULL) {
        PyEval_SaveThread();
    }
    if (PyThreadState_GetUnchecked() == NULL) {
        PyEval_RestoreThread(bootstrap);
    }
    PyThreadState_Clear(bootstrap);
    PyThreadState_DeleteCurrent();
    return status;
}

void
CPython_EndThreadState(PyThreadState *state)
{
    PyEval_RestoreThread(state);
    Py_EndInterpreter(state);
}

uintptr_t
CPython_InterpreterKey(PyThreadState *state)
{
    if (state == NULL) {
        state = PyThreadState_GetUnchecked();
    }
    return state == NULL ? 0 : (uintptr_t)PyThreadState_GetInterpreter(state);
}

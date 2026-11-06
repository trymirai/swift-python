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

static void
delete_bootstrap_state(PyThreadState *bootstrap, bool created_interpreter)
{
    // Creation switches to the new GIL. Free the temporary state under the main GIL.
    if (created_interpreter) {
        PyEval_SaveThread();
    }
    if (PyThreadState_GetUnchecked() == NULL) {
        PyEval_RestoreThread(bootstrap);
    }
    PyThreadState_Clear(bootstrap);
    PyThreadState_DeleteCurrent();
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
        .check_multi_interp_extensions = 1,

        .allow_fork = 0,
        .allow_exec = 0,
        .allow_threads = 0,
        .allow_daemon_threads = 0,

        .gil = PyInterpreterConfig_OWN_GIL,
    };

    PyEval_RestoreThread(bootstrap);
    PyStatus status = Py_NewInterpreterFromConfig(state, &config);
    delete_bootstrap_state(bootstrap, *state != NULL);
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

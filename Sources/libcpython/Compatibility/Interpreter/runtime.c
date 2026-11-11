#include "../embedded.h"
#include "../interpreter.h"
#include "checkpoint.h"
#include "host_value.h"

static _Thread_local void *current_scope;

void *
CPython_SetScope(void *scope)
{
    void *previous = current_scope;
    current_scope = scope;
    return previous;
}

void *
CPython_CurrentScope(void)
{
    return current_scope;
}

PyInterpreterView *
CPython_NewInterpreterView(PyThreadState *state)
{
    CPython_Heap *previous = CPython_BindHeap(NULL);
    PyEval_RestoreThread(state);
    PyInterpreterView *view = PyInterpreterView_FromCurrent();
    PyEval_SaveThread();
    CPython_BindHeap(previous);
    return view;
}

PyStatus
CPython_InitializeRuntime(void)
{
    if (CPython_InstallFileAudit() < 0) {
        return PyStatus_Error("Unable to install the Python file audit hook.");
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);

    config.install_signal_handlers = 0;
    config.site_import = 0;
    config.write_bytecode = 0;

    PyStatus status = CPython_Initialize(&config);
    PyConfig_Clear(&config);

    if (!PyStatus_Exception(status)) {
        CPython_InstallHeapTracking();
    }
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
CPython_NewThreadState(PyThreadState **state, CPython_Heap **heap)
{
    *state = NULL;
    if (heap != NULL) {
        *heap = NULL;
    }

    PyThreadState *bootstrap = PyThreadState_New(PyInterpreterState_Main());
    if (bootstrap == NULL) {
        return PyStatus_NoMemory();
    }

    CPython_Heap *tracking = heap == NULL ? NULL : CPython_NewHeap();
    if (heap != NULL && tracking == NULL) {
        delete_bootstrap_state(bootstrap, false);
        return PyStatus_NoMemory();
    }

    PyInterpreterConfig config = {
        .use_main_obmalloc = 0,
        .check_multi_interp_extensions = 1,
        .gil = PyInterpreterConfig_OWN_GIL,

        .allow_fork = 0,
        .allow_exec = 0,
        .allow_threads = 0,
        .allow_daemon_threads = 0,
    };

    // Bind before creation so a transactional interpreter tracks its first allocations.
    PyEval_RestoreThread(bootstrap);
    CPython_BindHeap(tracking);
    PyStatus status = Py_NewInterpreterFromConfig(state, &config);
    CPython_BindHeap(NULL);

    delete_bootstrap_state(bootstrap, *state != NULL);

    if (tracking != NULL) {
        if (PyStatus_Exception(status)) {
            CPython_FreeHeap(tracking);
        } else {
            *heap = tracking;
        }
    }
    return status;
}

void
CPython_EndThreadState(PyThreadState *state, CPython_Heap *heap)
{
    CPython_AttachThreadState(state, heap);
    Py_EndInterpreter(state);
    CPython_BindHeap(NULL);

    if (heap != NULL) {
        CPython_FreeHeap(heap);
    }
}

void
CPython_AttachThreadState(PyThreadState *state, CPython_Heap *heap)
{
    CPython_BindHeap(heap);
    PyEval_RestoreThread(state);
}

void
CPython_DetachThreadState(void)
{
    PyEval_SaveThread();
    CPython_BindHeap(NULL);
}

int
CPython_BeginCheckpoint(void)
{
    if (CPython_BeginHeapCheckpoint(PyThreadState_Get()) < 0) {
        return -1;
    }
    checkpoint_begin_host_values();
    return 0;
}

void
CPython_FinishCheckpoint(bool restoring)
{
    checkpoint_finish_host_values(!restoring);
    CPython_FinishHeapCheckpoint(PyThreadState_Get(), restoring);
}

uintptr_t
CPython_InterpreterKey(PyThreadState *state)
{
    if (state == NULL) {
        state = PyThreadState_GetUnchecked();
    }
    return state == NULL ? 0 : (uintptr_t)PyThreadState_GetInterpreter(state);
}

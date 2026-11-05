#include "../interpreter.h"

#include <stdlib.h>

typedef struct {
    void *context;
    bool (*interrupt)(void *context);
} Evaluation;

static const char evaluation_name[] = "swift-python.evaluation";

static void
destroy_evaluation(PyObject *capsule)
{
    free(PyCapsule_GetPointer(capsule, evaluation_name));
}

static int
trace_evaluation(PyObject *capsule, PyFrameObject *frame, int event, PyObject *argument)
{
    (void)frame;
    (void)argument;
    if (event != PyTrace_CALL && event != PyTrace_LINE) {
        return 0;
    }
    Evaluation *evaluation = PyCapsule_GetPointer(capsule, evaluation_name);
    if (evaluation == NULL) {
        return -1;
    }
    if (evaluation->context != NULL && evaluation->interrupt(evaluation->context)) {
        PyErr_SetNone(PyExc_KeyboardInterrupt);
        return -1;
    }
    return 0;
}

PyObject *
CPython_Evaluate(PyObject *function, PyObject *source, PyObject *filename, PyObject *control,
                 void *context, bool (*interrupt)(void *context))
{
    Evaluation *evaluation = malloc(sizeof(*evaluation));
    if (evaluation == NULL) {
        return PyErr_NoMemory();
    }
    *evaluation = (Evaluation){context, interrupt};
    PyObject *capsule = PyCapsule_New(evaluation, evaluation_name, destroy_evaluation);
    if (capsule == NULL) {
        free(evaluation);
        return NULL;
    }

    PyThreadState *state = PyThreadState_Get();
    Py_tracefunc previous = state->c_tracefunc;
    PyObject *previous_object = Py_XNewRef(state->c_traceobj);
    PyEval_SetTrace(trace_evaluation, capsule);
    if (state->c_tracefunc != trace_evaluation || state->c_traceobj != capsule) {
        evaluation->context = NULL;
        Py_XDECREF(previous_object);
        Py_DECREF(capsule);
        PyErr_SetString(PyExc_RuntimeError, "Unable to install the execution trace.");
        return NULL;
    }
    PyObject *result = CPython_Call3(function, source, filename, control);

    /* Restoring a trace can run Python audit hooks. Preserve the block error. */
    evaluation->context = NULL;
    PyObject *error = PyErr_GetRaisedException();
    PyEval_SetTrace(previous, previous_object);
    Py_XDECREF(previous_object);
    Py_DECREF(capsule);
    if (error != NULL) {
        PyErr_SetRaisedException(error);
    }
    return result;
}

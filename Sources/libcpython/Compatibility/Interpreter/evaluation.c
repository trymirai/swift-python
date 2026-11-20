#include "../interpreter.h"
#include "internal/pycore_ceval.h"

typedef struct {
    PyThreadState *thread;
    void *execution;

    PyObject *handler;
    bool deferred;
} LoopInterruption;

static _Thread_local CPython_Evaluation *current_evaluation;
static _Thread_local LoopInterruption *current_loop;

static LoopInterruption *
active_loop(void)
{
    if (current_loop != NULL && current_evaluation != NULL &&
        current_loop->execution == current_evaluation->context &&
        current_loop->thread == PyThreadState_Get()) {
        return current_loop;
    }
    return NULL;
}

PyObject *
CPython_DriveEventLoop(PyObject *Py_UNUSED(self), PyObject *const *args, Py_ssize_t nargs)
{
    if (nargs < 2) {
        PyErr_SetString(PyExc_TypeError, "Expected an interrupt handler and a loop driver.");
        return NULL;
    }

    LoopInterruption loop = {
        .thread = PyThreadState_Get(),
        .execution = current_evaluation != NULL ? current_evaluation->context : NULL,
        .handler = args[0],
    };

    LoopInterruption *previous = current_loop;
    current_loop = &loop;

    PyObject *result = PyObject_Vectorcall(args[1], args + 2, nargs - 2, NULL);

    current_loop = previous;
    return result;
}

void
CPython_ResumeDeferredInterruption(void)
{
    if (current_loop == NULL || !current_loop->deferred) {
        return;
    }

    // A ready handle is about to run in its own context and may never yield to the loop.
    LoopInterruption *loop = active_loop();
    if (loop != NULL) {
        CPython_RequestEvaluationInterrupt(loop->thread->interp);
    }
}

CPython_Evaluation *
CPython_SetEvaluation(CPython_Evaluation *evaluation)
{
    CPython_Evaluation *previous = current_evaluation;
    current_evaluation = evaluation;
    return previous;
}

static inline int
loop_should_interrupt(LoopInterruption *loop)
{
    loop->deferred = false;
    PyObject *decision = PyObject_CallNoArgs(loop->handler);
    if (decision == NULL) {
        return -1;
    }

    // False defers until a context switch. None leaves cancellation to the event loop.
    loop->deferred = decision == Py_False;
    bool interrupt = decision == Py_True;
    Py_DECREF(decision);
    return interrupt;
}

int
CPython_CheckEvaluation(void)
{
    CPython_Evaluation *evaluation = current_evaluation;
    if (evaluation == NULL || evaluation->context == NULL) {
        return 0;
    }

    LoopInterruption *loop = active_loop();
    bool deferred = loop != NULL && loop->deferred;
    if (!deferred && !evaluation->interrupt(evaluation->context)) {
        return 0;
    }

    if (loop != NULL) {
        int interrupt = loop_should_interrupt(loop);
        if (interrupt <= 0) {
            return interrupt;
        }
    }

    CPython_RaiseKeyboardInterrupt();
    return -1;
}

static int
check_pending_evaluation(void *unused)
{
    (void)unused;

    // The pending call may outlive the evaluation that queued it.
    return CPython_CheckEvaluation();
}

void
CPython_RequestEvaluationInterrupt(PyInterpreterState *interpreter)
{
    _PyEval_AddPendingCall(interpreter, check_pending_evaluation, NULL, 0);
}

PyObject *
CPython_CallInterruptibly(PyObject *function, PyObject *const *arguments, size_t argument_count,
                          void *context, bool (*interrupt)(void *context))
{
    CPython_Evaluation evaluation = {
        .context = context,
        .interrupt = interrupt,
    };
    CPython_Evaluation *previous = CPython_SetEvaluation(&evaluation);

    PyObject *result = NULL;
    if (CPython_CheckEvaluation() == 0) {
        result = PyObject_Vectorcall(function, arguments, argument_count, NULL);
    }

    CPython_SetEvaluation(previous);
    return result;
}

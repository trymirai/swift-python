#include "../interpreter.h"
#include "internal/pycore_ceval.h"

static _Thread_local CPython_Evaluation *current_evaluation;

CPython_Evaluation *
CPython_SetEvaluation(CPython_Evaluation *evaluation)
{
    CPython_Evaluation *previous = current_evaluation;
    current_evaluation = evaluation;
    return previous;
}

int
CPython_CheckEvaluation(void)
{
    CPython_Evaluation *evaluation = current_evaluation;
    if (evaluation != NULL && evaluation->context != NULL &&
        evaluation->interrupt(evaluation->context)) {
        CPython_RaiseKeyboardInterrupt();
        return -1;
    }
    return 0;
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

void
CPython_InterruptThreadState(PyThreadState *state)
{
    // The caller holds the interpreter's GIL. A successful exchange transfers the reference.
    PyObject *expected = NULL;
    Py_INCREF(PyExc_KeyboardInterrupt);
    if (_Py_atomic_compare_exchange_ptr(&state->async_exc, &expected, PyExc_KeyboardInterrupt)) {
        _Py_set_eval_breaker_bit(state, _PY_ASYNC_EXCEPTION_BIT);
    } else {
        Py_DECREF(PyExc_KeyboardInterrupt);
    }
}

bool
CPython_TakeThreadInterruption(void)
{
    PyThreadState *state = PyThreadState_Get();
    PyObject *expected = PyExc_KeyboardInterrupt;
    if (!_Py_atomic_compare_exchange_ptr(&state->async_exc, &expected, NULL)) {
        return false;
    }

    _Py_unset_eval_breaker_bit(state, _PY_ASYNC_EXCEPTION_BIT);
    Py_DECREF(PyExc_KeyboardInterrupt);
    return true;
}

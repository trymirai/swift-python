#include "../interpreter.h"
#include "internal/pycore_ceval.h"

// A queued call can outlive the block that requested it. Consult only the
// active evaluation on this interpreter thread.
static _Thread_local CPython_Evaluation *current_evaluation;

CPython_Evaluation *
CPython_SetEvaluation(CPython_Evaluation *evaluation)
{
    CPython_Evaluation *previous = current_evaluation;
    current_evaluation = evaluation;
    return previous;
}

void
CPython_InterruptThreadState(PyThreadState *state)
{
    // The interpreter is attached. Preserve an exception already queued for this state.
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

static int
deliver_interrupt(void *unused)
{
    (void)unused;
    CPython_Evaluation *evaluation = current_evaluation;
    if (evaluation != NULL && evaluation->context != NULL &&
        evaluation->interrupt(evaluation->context)) {
        CPython_RaiseKeyboardInterrupt();
        return -1;
    }
    return 0;
}

void
CPython_RequestEvaluationInterrupt(PyInterpreterState *interpreter)
{
    _PyEval_AddPendingCall(interpreter, deliver_interrupt, NULL, 0);
}

PyObject *
CPython_CallInterruptibly(PyObject *function, PyObject *const *arguments, size_t argument_count,
                          void *context, bool (*interrupt)(void *context))
{
    CPython_Evaluation evaluation = {context, interrupt};
    CPython_Evaluation *previous = CPython_SetEvaluation(&evaluation);
    PyObject *result = deliver_interrupt(NULL) == 0
        ? PyObject_Vectorcall(function, arguments, argument_count, NULL)
        : NULL;
    CPython_SetEvaluation(previous);
    return result;
}

int
CPython_CheckEvaluation(void)
{
    return deliver_interrupt(NULL);
}

#include "../interpreter.h"
#include "internal/pycore_ceval.h"

typedef struct {
    void *context;
    bool (*interrupt)(void *context);
} Evaluation;

// A queued call can outlive the block that requested it. Consult only the
// active evaluation on this interpreter thread.
static _Thread_local Evaluation *current_evaluation;

static int
deliver_interrupt(void *unused)
{
    (void)unused;
    Evaluation *evaluation = current_evaluation;
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
    Evaluation evaluation = {context, interrupt};
    Evaluation *previous = current_evaluation;
    current_evaluation = &evaluation;
    PyObject *result = deliver_interrupt(NULL) == 0
        ? PyObject_Vectorcall(function, arguments, argument_count, NULL)
        : NULL;
    current_evaluation = previous;
    return result;
}

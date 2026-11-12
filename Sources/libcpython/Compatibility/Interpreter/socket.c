#include "../interpreter.h"
#include "internal/pycore_time.h"

#include <errno.h>
#include <poll.h>

static inline int
check_interruption(void)
{
    if (CPython_CheckEvaluation() < 0) {
        errno = EINTR;
        return -1;
    }
    return 0;
}

static inline int
poll_timeout(int64_t timeout, PyTime_t deadline)
{
    // Bound each wait so an interrupted execution can regain the interpreter.
    const PyTime_t maximum = _PyTime_FromSeconds(1) / 20;
    PyTime_t interval = timeout < 0 ? maximum : _PyDeadline_Get(deadline);
    if (interval < 0) {
        interval = 0;
    }
    if (interval > maximum) {
        interval = maximum;
    }
    return (int)_PyTime_AsMilliseconds(interval, _PyTime_ROUND_CEILING);
}

int
CPython_WaitForSocket(int fd, bool writing, int64_t timeout)
{
    if (fd < 0) {
        errno = EBADF;
        PyErr_SetFromErrno(PyExc_OSError);
        return -1;
    }

    PyTime_t deadline = timeout < 0 ? 0 : _PyDeadline_Init(timeout);
    struct pollfd descriptor = {.fd = fd, .events = writing ? POLLOUT : POLLIN};
    for (;;) {
        if (check_interruption() < 0) {
            return -1;
        }

        int milliseconds = poll_timeout(timeout, deadline);
        int result;
        Py_BEGIN_ALLOW_THREADS
        result = poll(&descriptor, 1, milliseconds);
        Py_END_ALLOW_THREADS

        if (check_interruption() < 0) {
            return -1;
        }
        if (result > 0) {
            return 0;
        }
        if (result < 0 && errno != EINTR) {
            return -1;
        }
        if (timeout >= 0 && _PyDeadline_Get(deadline) <= 0) {
            return 1;
        }
    }
}

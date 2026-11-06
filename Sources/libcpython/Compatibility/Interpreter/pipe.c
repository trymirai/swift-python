#include "../interpreter.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

int
CPython_NewPipe(int *reader, int *writer)
{
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        return errno;
    }

    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) != 0) {
        int error = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        return error;
    }

    *reader = descriptors[0];
    *writer = descriptors[1];
    return 0;
}

int
CPython_WaitForCall(int reply_fd, int interruption_fd)
{
    if (reply_fd < 0 || interruption_fd < 0) {
        return EBADF;
    }

    struct pollfd descriptors[] = {
        {.fd = reply_fd, .events = POLLIN},
        {.fd = interruption_fd, .events = POLLIN},
    };

    PyThreadState *thread_state = PyEval_SaveThread();
    int ready;
    do {
        ready = poll(descriptors, 2, -1);
    } while (ready < 0 && errno == EINTR);

    // Reattaching the interpreter can overwrite the polling error.
    int poll_error = errno;
    PyEval_RestoreThread(thread_state);

    if (ready < 0) {
        return poll_error;
    }

    int events = descriptors[0].revents | descriptors[1].revents;
    return (events & POLLNVAL) != 0 ? EBADF : 0;
}

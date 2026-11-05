#include "../interpreter.h"

#include <errno.h>
#include <fcntl.h>
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

#include "../thread.h"

#include <pthread.h>

int
CPython_StartThread(void *(*entry)(void *), void *context)
{
    pthread_attr_t attributes;
    int error = pthread_attr_init(&attributes);
    if (error != 0) {
        return error;
    }

    /* CPython can exhaust the default stack of an Apple worker thread. */
    error = pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
    if (error == 0) {
        error = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    }
    if (error == 0) {
        pthread_t thread;
        error = pthread_create(&thread, &attributes, entry, context);
    }
    pthread_attr_destroy(&attributes);
    return error;
}

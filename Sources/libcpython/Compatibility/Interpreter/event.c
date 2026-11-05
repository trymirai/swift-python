#include "../thread.h"

#include <pthread.h>
#include <stdlib.h>

struct CPython_ThreadEvent {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    bool pending;
};

static _Thread_local const CPython_ThreadEvent *current_event;

CPython_ThreadEvent *
CPython_ThreadEvent_New(void)
{
    CPython_ThreadEvent *event = calloc(1, sizeof(*event));
    if (event == NULL) {
        return NULL;
    }
    if (pthread_mutex_init(&event->lock, NULL) != 0) {
        free(event);
        return NULL;
    }
    if (pthread_cond_init(&event->condition, NULL) != 0) {
        pthread_mutex_destroy(&event->lock);
        free(event);
        return NULL;
    }
    return event;
}

void
CPython_ThreadEvent_Free(CPython_ThreadEvent *event)
{
    pthread_cond_destroy(&event->condition);
    pthread_mutex_destroy(&event->lock);
    free(event);
}

void
CPython_ThreadEvent_Bind(CPython_ThreadEvent *event)
{
    current_event = event;
}

bool
CPython_ThreadEvent_IsCurrent(const CPython_ThreadEvent *event)
{
    return current_event == event;
}

void
CPython_ThreadEvent_Signal(CPython_ThreadEvent *event)
{
    pthread_mutex_lock(&event->lock);
    event->pending = true;
    pthread_cond_signal(&event->condition);
    pthread_mutex_unlock(&event->lock);
}

void
CPython_ThreadEvent_Wait(CPython_ThreadEvent *event)
{
    pthread_mutex_lock(&event->lock);
    while (!event->pending) {
        pthread_cond_wait(&event->condition, &event->lock);
    }
    event->pending = false;
    pthread_mutex_unlock(&event->lock);
}

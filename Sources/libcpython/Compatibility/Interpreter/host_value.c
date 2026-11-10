#include "host_value.h"
#include "../interpreter.h"

#include <assert.h>

static _Thread_local struct {
    uintptr_t interpreter;

    HostValue *created;
    HostValue *retired;
} checkpoint;

static bool
is_active(void)
{
    return checkpoint.interpreter != 0 && checkpoint.interpreter == CPython_InterpreterKey(NULL);
}

static void
insert(HostValue **head, HostValue *value)
{
    assert(value->list == NULL);
    value->list = head;
    value->next = *head;

    if (*head != NULL) {
        (*head)->previous = value;
    }
    *head = value;
}

static void
remove_value(HostValue *value)
{
    if (value->previous != NULL) {
        value->previous->next = value->next;
    } else {
        *value->list = value->next;
    }
    if (value->next != NULL) {
        value->next->previous = value->previous;
    }

    value->list = NULL;
    value->previous = NULL;
    value->next = NULL;
}

static void
drain(HostValue **head, bool dispose)
{
    while (*head != NULL) {
        HostValue *value = *head;
        remove_value(value);
        if (dispose) {
            value->dispose(value);
        }
    }
}

void
checkpoint_begin_host_values(void)
{
    assert(checkpoint.interpreter == 0);
    checkpoint.interpreter = CPython_InterpreterKey(NULL);
    assert(checkpoint.interpreter != 0);
}

void
checkpoint_finish_host_values(bool commit)
{
    assert(is_active());
    // Disposers can release more values. Those releases must happen outside the checkpoint.
    checkpoint.interpreter = 0;

    drain(&checkpoint.retired, commit);
    drain(&checkpoint.created, !commit);
}

PyObject *
host_value_capsule(HostValue *value, const char *name, PyCapsule_Destructor destroy)
{
    PyObject *capsule = PyCapsule_New(value, name, destroy);
    if (capsule == NULL) {
        value->dispose(value);
        return NULL;
    }

    if (is_active()) {
        insert(&checkpoint.created, value);
    }
    return capsule;
}

void
checkpoint_release_host_value(HostValue *value)
{
    if (value->list == &checkpoint.created) {
        remove_value(value);
    } else if (is_active()) {
        insert(&checkpoint.retired, value);
        return;
    }
    value->dispose(value);
}

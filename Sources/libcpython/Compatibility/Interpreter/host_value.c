#include "host_value.h"
#include "checkpoint.h"
#include "../interpreter.h"

#include <assert.h>

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
    HostValueCheckpoint *checkpoint = CPython_CurrentHostCheckpoint();
    assert(checkpoint != NULL && !checkpoint->active);
    checkpoint->active = true;
}

void
checkpoint_finish_host_values(bool commit)
{
    HostValueCheckpoint *checkpoint = CPython_CurrentHostCheckpoint();
    assert(checkpoint != NULL && checkpoint->active);
    // Disposers can release more values. Those releases must happen outside the checkpoint.
    checkpoint->active = false;

    drain(&checkpoint->retired, commit);
    drain(&checkpoint->created, !commit);
}

PyObject *
host_value_capsule(HostValue *value, const char *name, PyCapsule_Destructor destroy)
{
    PyObject *capsule = PyCapsule_New(value, name, destroy);
    if (capsule == NULL) {
        value->dispose(value);
        return NULL;
    }

    HostValueCheckpoint *checkpoint = CPython_CurrentHostCheckpoint();
    if (checkpoint != NULL && checkpoint->active) {
        insert(&checkpoint->created, value);
    }
    return capsule;
}

void
checkpoint_release_host_value(HostValue *value)
{
    HostValueCheckpoint *checkpoint = CPython_CurrentHostCheckpoint();
    if (checkpoint != NULL && value->list == &checkpoint->created) {
        remove_value(value);
    } else if (checkpoint != NULL && checkpoint->active) {
        insert(&checkpoint->retired, value);
        return;
    }
    value->dispose(value);
}

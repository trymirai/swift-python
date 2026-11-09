#ifndef SWIFT_PYTHON_HOST_VALUE_H
#define SWIFT_PYTHON_HOST_VALUE_H

#include "Python.h"

#include <stdbool.h>

typedef struct HostValue HostValue;

// The owning payload embeds this as its first member, at the capsule's address.
struct HostValue {
    HostValue *previous;
    HostValue *next;
    HostValue **list;

    void (*dispose)(HostValue *);
};

PyObject *host_value_capsule(HostValue *value, const char *name, PyCapsule_Destructor destroy);
void checkpoint_release_host_value(HostValue *value);

void checkpoint_begin_host_values(void);
void checkpoint_finish_host_values(bool commit);

#endif

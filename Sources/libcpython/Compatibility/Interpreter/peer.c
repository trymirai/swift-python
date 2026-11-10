#include "../interpreter.h"
#include "host_value.h"

#include <stdlib.h>

typedef struct {
    HostValue lifetime;

    void *value;
    void (*destroy)(void *);
} SwiftPeer;

static const char peer_name[] = "swift-python.peer";

static void
free_peer(HostValue *value)
{
    SwiftPeer *peer = (SwiftPeer *)value;
    peer->destroy(peer->value);
    free(peer);
}

static void
destroy_peer(PyObject *capsule)
{
    SwiftPeer *peer = PyCapsule_GetPointer(capsule, peer_name);
    if (peer != NULL) {
        checkpoint_release_host_value(&peer->lifetime);
    }
}

PyObject *
CPython_NewPeer(void *value, void (*destroy)(void *))
{
    SwiftPeer *peer = malloc(sizeof(*peer));
    if (peer == NULL) {
        destroy(value);
        return PyErr_NoMemory();
    }

    *peer = (SwiftPeer){
        .lifetime = {.dispose = free_peer},
        .value = value,
        .destroy = destroy,
    };

    return host_value_capsule(&peer->lifetime, peer_name, destroy_peer);
}

void *
CPython_GetPeer(PyObject *capsule)
{
    SwiftPeer *peer = PyCapsule_GetPointer(capsule, peer_name);
    return peer == NULL ? NULL : peer->value;
}

int
CPython_FreezeType(PyObject *type)
{
    if (!PyType_Check(type)) {
        PyErr_SetString(PyExc_TypeError, "Expected a native class.");
        return -1;
    }
    return PyType_Freeze((PyTypeObject *)type);
}

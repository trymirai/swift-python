#include "../interpreter.h"

#include <stdlib.h>

typedef struct {
    void *value;
    void (*destroy)(void *);
} SwiftPeer;

static const char peer_name[] = "swift-python.peer";

static void
free_peer(SwiftPeer *peer)
{
    peer->destroy(peer->value);
    free(peer);
}

static void
destroy_peer(PyObject *capsule)
{
    SwiftPeer *peer = PyCapsule_GetPointer(capsule, peer_name);
    if (peer != NULL) {
        free_peer(peer);
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
    *peer = (SwiftPeer){.value = value, .destroy = destroy};

    PyObject *capsule = PyCapsule_New(peer, peer_name, destroy_peer);
    if (capsule == NULL) {
        free_peer(peer);
    }
    return capsule;
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

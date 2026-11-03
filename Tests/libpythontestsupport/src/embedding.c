#include "pythontestsupport.h"

#include "Python.h"
#include "embedded.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    const char *code;
    int result;
} Check;

static void *
check_embedding(void *argument)
{
    Check *check = argument;
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    PyStatus status = CPython_Initialize(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        const char *message = status.err_msg != NULL ? status.err_msg : "unknown error";
        fprintf(stderr, "Embedded Python initialization failed: %s\n", message);
        if (Py_IsInitialized()) {
            PyErr_Print();
            Py_FinalizeEx();
        }
        return NULL;
    }
    check->result = PyRun_SimpleStringFlags(check->code, NULL);
    if (Py_FinalizeEx() < 0) {
        check->result = -1;
    }
    return NULL;
}

int
CPython_CheckEmbedding(const char *code)
{
    /* Swift Testing's worker threads may have only 512 KiB of C stack. A real
       interpreter executor needs a controlled stack and thread-state lifetime. */
    pthread_attr_t attributes;
    int error = pthread_attr_init(&attributes);
    if (error != 0) {
        return error;
    }
    error = pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
    if (error != 0) {
        pthread_attr_destroy(&attributes);
        return error;
    }
    Check check = {code, -1};
    pthread_t thread;
    error = pthread_create(&thread, &attributes, check_embedding, &check);
    pthread_attr_destroy(&attributes);
    if (error != 0) {
        return error;
    }
    // This joinable thread ID is private. A failed join cannot release borrowed code/work storage.
    if (pthread_join(thread, NULL) != 0) {
        abort();
    }
    return check.result;
}

#include "../interpreter.h"
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#include <sanitizer/asan_interface.h>
#define SWIFT_PYTHON_ASAN 1
#endif
#endif

#ifndef SWIFT_PYTHON_ASAN
#define SWIFT_PYTHON_ASAN 0
#endif

typedef struct ExportNode {
    CPython_ExportRegistration registration;
    struct ExportNode *next;
} ExportNode;

static pthread_mutex_t export_lock = PTHREAD_MUTEX_INITIALIZER;
static ExportNode *exports;

void
CPython_RegisterExport(CPython_ExportRegistration registration)
{
    ExportNode *node = malloc(sizeof(*node));
    if (node == NULL) {
        abort();
    }
    node->registration = registration;
    pthread_mutex_lock(&export_lock);
    node->next = exports;
    exports = node;
    pthread_mutex_unlock(&export_lock);
}

#if defined(__APPLE__) && defined(__MACH__)
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>

// Registering this callback also visits images already loaded. Export-bearing
// images must remain loaded for the lifetime of the sessions using their code.
static pthread_once_t discovery_once = PTHREAD_ONCE_INIT;

static void
discover_image(const struct mach_header *header, intptr_t slide)
{
    (void)slide;
    if (header == NULL || header->magic != MH_MAGIC_64) {
        return;
    }
    unsigned long size = 0;
    const CPython_ExportRegistration *records = (const void *)getsectiondata(
        (const struct mach_header_64 *)header, "__DATA", "__pyexports", &size);
    if (records == NULL || size % sizeof(*records) != 0 ||
        (uintptr_t)records % _Alignof(CPython_ExportRegistration) != 0) {
        return;
    }
    for (size_t i = 0; i < size / sizeof(*records); ++i) {
#if SWIFT_PYTHON_ASAN
        // ASan inserts redzones between section globals. Those bytes are not records.
        if (__asan_region_is_poisoned((void *)&records[i], sizeof(records[i])) != NULL) {
            continue;
        }
#endif
        if (records[i] != NULL) {
            CPython_RegisterExport(records[i]);
        }
    }
}

static void
initialize_discovery(void)
{
    _dyld_register_func_for_add_image(discover_image);
}
#endif

void
CPython_DiscoverExports(void *collector, CPython_ExportConsumer consume)
{
#if defined(__APPLE__) && defined(__MACH__)
    pthread_once(&discovery_once, initialize_discovery);
#endif
    pthread_mutex_lock(&export_lock);
    size_t count = 0;
    for (ExportNode *node = exports; node != NULL; node = node->next) {
        if (count == SIZE_MAX / sizeof(CPython_ExportRegistration)) {
            abort();
        }
        count++;
    }
    CPython_ExportRegistration *snapshot = count == 0 ? NULL : malloc(count * sizeof(*snapshot));
    if (count != 0 && snapshot == NULL) {
        abort();
    }
    size_t index = 0;
    for (ExportNode *node = exports; node != NULL; node = node->next) {
        snapshot[index++] = node->registration;
    }
    pthread_mutex_unlock(&export_lock);
    // Swift metadata access and user definitions happen outside loader callbacks
    // and outside the registry mutex.
    for (size_t i = 0; i < count; ++i) {
        snapshot[i](collector, consume);
    }
    free(snapshot);
}

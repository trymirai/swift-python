#include "checkpoint.h"
#include "internal/pycore_ceval.h"
#include "internal/pycore_interp_structs.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    PyMemAllocatorEx allocator;
} Domain;

struct CPython_Heap {
    unsigned char *snapshot;
};

typedef struct {
    uintptr_t address;
    size_t size;

    CPython_Heap *owner;
    Domain *domain;

    // Offsets refer to the owner's snapshot. Retired baseline blocks stay allocated until commit.
    size_t offset;
    bool baseline;
    bool retired;
} Allocation;

static pthread_mutex_t ledger_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic size_t heap_count;

static Allocation *ledger;
static size_t capacity;
static size_t count;
static size_t occupied; // Includes tombstones, which lengthen lookups.

static Domain domains[3];

// The worker binds its heap while CPython is attached or initializing.
static _Thread_local CPython_Heap *active_heap;
static _Thread_local bool in_allocator;

enum { empty = 0, deleted = 1 };

static Allocation *
find_slot(Allocation *slots, size_t slot_count, uintptr_t address)
{
    size_t index = ((address >> 4) ^ (address >> 17)) & (slot_count - 1);
    Allocation *available = NULL;
    for (;;) {
        Allocation *slot = &slots[index];
        if (slot->address == address) {
            return slot;
        }
        if (slot->address == empty) {
            return available != NULL ? available : slot;
        }
        if (slot->address == deleted && available == NULL) {
            available = slot;
        }
        index = (index + 1) & (slot_count - 1);
    }
}

static bool
rebuild_ledger(size_t target)
{
    Allocation *slots = calloc(target, sizeof(*slots));
    if (slots == NULL) {
        return false;
    }
    for (size_t index = 0; index < capacity; index++) {
        Allocation *slot = &ledger[index];
        if (slot->address > deleted) {
            *find_slot(slots, target, slot->address) = *slot;
        }
    }
    free(ledger);
    ledger = slots;
    capacity = target;
    occupied = count;
    return true;
}

static bool
reserve_slot(void)
{
    if (occupied < capacity / 2) {
        return true;
    }
    if (capacity == 0) {
        return rebuild_ledger(1024);
    }

    // Rehash at the current capacity if tombstones account for most of the occupied slots.
    if (count < capacity / 4) {
        return rebuild_ledger(capacity);
    }
    return capacity <= SIZE_MAX / sizeof(Allocation) / 2 && rebuild_ledger(capacity * 2);
}

static Allocation *
lookup(void *pointer)
{
    if (pointer == NULL || capacity == 0) {
        return NULL;
    }

    uintptr_t address = (uintptr_t)pointer;
    Allocation *slot = find_slot(ledger, capacity, address);
    return slot->address == address ? slot : NULL;
}

static void
record(Domain *domain, CPython_Heap *owner, void *pointer, size_t size)
{
    if (pointer == NULL) {
        return;
    }
    uintptr_t address = (uintptr_t)pointer;
    Allocation *slot = find_slot(ledger, capacity, address);
    assert(slot->address <= deleted);
    occupied += slot->address == empty;
    count++;
    *slot = (Allocation){
        .address = address, .size = size == 0 ? 1 : size, .owner = owner, .domain = domain};
}

static void
remove_allocation(Allocation *slot)
{
    *slot = (Allocation){.address = deleted};
    count--;
}

static inline void *
allocate_untracked(PyMemAllocatorEx *allocator, size_t elements, size_t size, bool zeroed)
{
    return zeroed ? allocator->calloc(allocator->ctx, elements, size)
                  : allocator->malloc(allocator->ctx, size);
}

static void *
allocate(Domain *domain, size_t elements, size_t size, bool zeroed)
{
    PyMemAllocatorEx *allocator = &domain->allocator;
    if (in_allocator || active_heap == NULL) {
        return allocate_untracked(allocator, elements, size, zeroed);
    }

    pthread_mutex_lock(&ledger_lock);
    void *pointer = NULL;
    if (reserve_slot()) {
        in_allocator = true;
        pointer = allocate_untracked(allocator, elements, size, zeroed);
        in_allocator = false;
        record(domain, active_heap, pointer, elements * size);
    }
    pthread_mutex_unlock(&ledger_lock);
    return pointer;
}

static void *
tracked_malloc(void *context, size_t size)
{
    return allocate(context, 1, size, false);
}

static void *
tracked_calloc(void *context, size_t count, size_t size)
{
    if (count != 0 && size > SIZE_MAX / count) {
        return NULL;
    }
    return allocate(context, count, size, true);
}

static void *
resize_allocation(PyMemAllocatorEx *allocator, Allocation *slot, void *pointer, size_t size)
{
    if (slot != NULL && slot->baseline) {
        // Preserve the old block at its original address in case the checkpoint is restored.
        void *replacement = allocator->malloc(allocator->ctx, size);
        if (replacement != NULL) {
            memcpy(replacement, pointer, size < slot->size ? size : slot->size);
            slot->retired = true;
        }
        return replacement;
    }

    void *replacement = allocator->realloc(allocator->ctx, pointer, size);
    if (slot != NULL && replacement != NULL) {
        remove_allocation(slot);
    }
    return replacement;
}

static void *
tracked_realloc(void *context, void *pointer, size_t size)
{
    Domain *domain = context;
    PyMemAllocatorEx *allocator = &domain->allocator;
    if (in_allocator || atomic_load_explicit(&heap_count, memory_order_relaxed) == 0) {
        return allocator->realloc(allocator->ctx, pointer, size);
    }

    pthread_mutex_lock(&ledger_lock);
    Allocation *slot = lookup(pointer);
    CPython_Heap *owner = slot != NULL ? slot->owner : (pointer == NULL ? active_heap : NULL);
    if (owner != NULL) {
        // Reserve before realloc can consume the original pointer.
        if (!reserve_slot()) {
            pthread_mutex_unlock(&ledger_lock);
            return NULL;
        }
        // Growth may have moved the table. Re-find the original entry.
        slot = lookup(pointer);
    }

    in_allocator = true;
    void *replacement = resize_allocation(allocator, slot, pointer, size);
    in_allocator = false;

    if (owner != NULL) {
        record(domain, owner, replacement, size);
    }
    pthread_mutex_unlock(&ledger_lock);
    return replacement;
}

static void
tracked_free(void *context, void *pointer)
{
    Domain *domain = context;
    PyMemAllocatorEx *allocator = &domain->allocator;
    if (pointer == NULL || in_allocator ||
        atomic_load_explicit(&heap_count, memory_order_relaxed) == 0) {
        allocator->free(allocator->ctx, pointer);
        return;
    }

    pthread_mutex_lock(&ledger_lock);
    Allocation *slot = lookup(pointer);
    if (slot != NULL && slot->baseline) {
        slot->retired = true;
    } else {
        if (slot != NULL) {
            remove_allocation(slot);
        }
        in_allocator = true;
        allocator->free(allocator->ctx, pointer);
        in_allocator = false;
    }
    pthread_mutex_unlock(&ledger_lock);
}

int
CPython_InstallHeapTracking(void)
{
    for (int index = PYMEM_DOMAIN_RAW; index <= PYMEM_DOMAIN_OBJ; index++) {
        Domain *domain = &domains[index];
        PyMem_GetAllocator(index, &domain->allocator);
        PyMemAllocatorEx wrapper = {domain, tracked_malloc, tracked_calloc, tracked_realloc,
                                    tracked_free};
        PyMem_SetAllocator(index, &wrapper);
    }
    return 0;
}

CPython_Heap *
CPython_NewHeap(void)
{
    CPython_Heap *heap = calloc(1, sizeof(*heap));
    if (heap != NULL) {
        atomic_fetch_add_explicit(&heap_count, 1, memory_order_relaxed);
    }
    return heap;
}

void
CPython_FreeHeap(CPython_Heap *heap)
{
    assert(heap->snapshot == NULL);
    pthread_mutex_lock(&ledger_lock);
    for (size_t index = 0; index < capacity; index++) {
        Allocation *slot = &ledger[index];
        if (slot->owner == heap) {
            // Some allocations outlive their interpreter. CPython still owns their storage.
            remove_allocation(slot);
        }
    }
    if (atomic_fetch_sub_explicit(&heap_count, 1, memory_order_relaxed) == 1) {
        free(ledger);
        ledger = NULL;
        capacity = 0;
        assert(count == 0);
        occupied = 0;
    }
    pthread_mutex_unlock(&ledger_lock);
    free(heap);
}

void
CPython_BindHeap(CPython_Heap *heap)
{
    active_heap = heap;
}

typedef struct {
    uintptr_t start;
    uintptr_t end;
} Range;

static int
compare_ranges(const void *left, const void *right)
{
    const Range *first = left;
    const Range *second = right;
    return (first->start > second->start) - (first->start < second->start);
}

static bool
is_snapshot_allocation(const Allocation *slot, const CPython_Heap *heap,
                       const PyInterpreterState *interpreter)
{
    return slot->owner == heap && slot->address != (uintptr_t)interpreter->obmalloc;
}

static void
copy_allocation_ranges(const Allocation *slot, unsigned char *snapshot, bool restoring,
                       const Range *excluded, size_t excluded_count)
{
    uintptr_t start = slot->address;
    uintptr_t end = start + slot->size;
    uintptr_t cursor = start;

    unsigned char *live = (unsigned char *)start;
    unsigned char *saved = snapshot + slot->offset;
    unsigned char *destination = restoring ? live : saved;
    const unsigned char *source = restoring ? saved : live;

    for (size_t field = 0; field < excluded_count && cursor < end; field++) {
        Range range = excluded[field];
        if (range.end <= cursor || range.start >= end) {
            continue;
        }
        if (range.start > cursor) {
            memcpy(destination + (cursor - start), source + (cursor - start), range.start - cursor);
        }
        cursor = range.end;
    }
    if (cursor < end) {
        memcpy(destination + (cursor - start), source + (cursor - start), end - cursor);
    }
}

#define FIELD(object, member) {(uintptr_t)&(object)->member, (uintptr_t)(&(object)->member + 1)}

static void
copy_private_bytes(PyThreadState *state, CPython_Heap *heap, bool restoring)
{
    PyInterpreterState *interpreter = PyThreadState_GetInterpreter(state);
    _PyThreadStateImpl *impl = (_PyThreadStateImpl *)state;

    // Rollback preserves live registry links, synchronization state, and separately owned stacks.
    Range excluded[] = {
        FIELD(interpreter, next),
        FIELD(interpreter, id_refcount),
        FIELD(interpreter, requires_idref),

        FIELD(interpreter, ceval.pending),
        FIELD(interpreter, _gil),
        FIELD(interpreter, finalization_guards),

        FIELD(state, eval_breaker),
        FIELD(state, _status),
        FIELD(state, holds_gil),
        FIELD(state, gil_requested),
        FIELD(state, state),

        FIELD(state, last_profiled_frame),
        FIELD(state, last_profiled_frame_seq),
        FIELD(state, remote_debugger_support),

        {(uintptr_t)&state->datastack_chunk, (uintptr_t)(&state->datastack_cached_chunk + 1)},
        FIELD(state, dict_global_version),

        FIELD(impl, refcount),
    };
    qsort(excluded, Py_ARRAY_LENGTH(excluded), sizeof(*excluded), compare_ranges);

    for (size_t index = 0; index < capacity; index++) {
        Allocation *slot = &ledger[index];
        if (!is_snapshot_allocation(slot, heap, interpreter) || (restoring && !slot->baseline)) {
            continue;
        }
        copy_allocation_ranges(slot, heap->snapshot, restoring, excluded,
                               Py_ARRAY_LENGTH(excluded));
    }
}

#undef FIELD

static unsigned char *
allocate_snapshot(CPython_Heap *heap, PyInterpreterState *interpreter)
{
    size_t bytes = 0;
    for (size_t index = 0; index < capacity; index++) {
        Allocation *slot = &ledger[index];
        if (!is_snapshot_allocation(slot, heap, interpreter)) {
            continue;
        }
        if (slot->size > SIZE_MAX - bytes) {
            return NULL;
        }
        slot->offset = bytes;
        bytes += slot->size;
    }
    return malloc(bytes == 0 ? 1 : bytes);
}

static void
mark_baseline_allocations(CPython_Heap *heap)
{
    for (size_t index = 0; index < capacity; index++) {
        if (ledger[index].owner == heap) {
            ledger[index].baseline = true;
        }
    }
}

int
CPython_BeginHeapCheckpoint(PyThreadState *state)
{
    assert(PyThreadState_GetUnchecked() == state);
    CPython_Heap *heap = active_heap;
    assert(heap != NULL && heap->snapshot == NULL);
    PyInterpreterState *interpreter = PyThreadState_GetInterpreter(state);

    pthread_mutex_lock(&ledger_lock);
    heap->snapshot = allocate_snapshot(heap, interpreter);
    if (heap->snapshot == NULL) {
        pthread_mutex_unlock(&ledger_lock);
        return -1;
    }

    copy_private_bytes(state, heap, false);
    mark_baseline_allocations(heap);
    pthread_mutex_unlock(&ledger_lock);
    return 0;
}

static void
restore_eval_breaker(PyThreadState *state)
{
    // Keep pending-call flags from other threads while restoring the instrumentation version.
    PyInterpreterState *interpreter = PyThreadState_GetInterpreter(state);
    uintptr_t version =
        interpreter->ceval.instrumentation_version & ~((uintptr_t)_PY_EVAL_EVENTS_MASK);
    uintptr_t flags = _Py_atomic_load_uintptr(&state->eval_breaker);
    while (!_Py_atomic_compare_exchange_uintptr(&state->eval_breaker, &flags,
                                                version | (flags & _PY_EVAL_EVENTS_MASK))) {
    }
}

static void
finish_checkpoint_allocations(CPython_Heap *heap, bool restoring)
{
    in_allocator = true;
    for (size_t index = 0; index < capacity; index++) {
        Allocation *slot = &ledger[index];
        if (slot->owner != heap) {
            continue;
        }
        bool discard = restoring ? !slot->baseline : slot->retired;
        if (discard) {
            PyMemAllocatorEx *allocator = &slot->domain->allocator;
            allocator->free(allocator->ctx, (void *)slot->address);
            remove_allocation(slot);
        } else {
            slot->baseline = false;
            slot->retired = false;
        }
    }
    in_allocator = false;
}

void
CPython_FinishHeapCheckpoint(PyThreadState *state, bool restoring)
{
    assert(PyThreadState_GetUnchecked() == state);
    CPython_Heap *heap = active_heap;
    assert(heap != NULL && heap->snapshot != NULL);

    pthread_mutex_lock(&ledger_lock);
    if (restoring) {
        copy_private_bytes(state, heap, true);
        restore_eval_breaker(state);
    }
    finish_checkpoint_allocations(heap, restoring);

    free(heap->snapshot);
    heap->snapshot = NULL;
    pthread_mutex_unlock(&ledger_lock);
}

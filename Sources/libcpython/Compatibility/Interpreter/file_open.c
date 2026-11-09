#include "../file_open.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct {
    int fd;
    bool closed;
    off_t offset;
} Descriptor;

struct CPython_Files {
    Descriptor *descriptors;
    size_t count;
    size_t capacity;

    size_t checkpoint_count;
    bool checkpoint;

    int streams[3];
};

static _Thread_local CPython_FileAccessCheck check_file;
static _Thread_local void *check_context;
static _Thread_local CPython_Files *files;

CPython_Files *
CPython_NewFiles(void)
{
    CPython_Files *state = calloc(1, sizeof(*state));
    if (state != NULL) {
        for (size_t i = 0; i < 3; ++i) {
            state->streams[i] = -1;
        }
    }
    return state;
}

void
CPython_FreeFiles(CPython_Files *state)
{
    if (state != NULL) {
        for (size_t i = 0; i < state->count; ++i) {
            close(state->descriptors[i].fd);
        }
        free(state->descriptors);
        free(state);
    }
}

void
CPython_SetFileAccessCheck(CPython_FileAccessCheck check, void *context, CPython_Files *state)
{
    check_file = check;
    check_context = context;
    files = state;
}

bool
CPython_RestrictedFiles(void)
{
    return files != NULL;
}

void
CPython_SetStreamDescriptors(int input, int output, int error)
{
    if (files != NULL) {
        files->streams[0] = input;
        files->streams[1] = output;
        files->streams[2] = error;
    }
}

static bool
is_stream(int fd)
{
    return fd >= 0 &&
           (fd == files->streams[0] || fd == files->streams[1] || fd == files->streams[2]);
}

static Descriptor *
require_descriptor(int fd)
{
    for (size_t i = 0; i < files->count; ++i) {
        Descriptor *entry = &files->descriptors[i];
        if (entry->fd == fd && !entry->closed) {
            return entry;
        }
    }
    errno = EBADF;
    return NULL;
}

int
CPython_RequireFileDescriptor(int fd, bool borrowing_stream)
{
    if (files == NULL) {
        return 0;
    }
    if (borrowing_stream && is_stream(fd)) {
        return 0;
    }
    return require_descriptor(fd) == NULL ? -1 : 0;
}

int
CPython_CloseFileDescriptor(int fd)
{
    if (files == NULL) {
        return close(fd);
    }
    Descriptor *entry = require_descriptor(fd);
    if (entry == NULL) {
        return -1;
    }
    if (files->checkpoint) {
        // Keep the number reserved until commit. A restored FileIO must still own it.
        entry->closed = true;
        return 0;
    }
    *entry = files->descriptors[--files->count];
    return close(fd);
}

int
CPython_TruncateFileDescriptor(int fd, off_t size)
{
    if (CPython_RequireFileDescriptor(fd, false) < 0) {
        return -1;
    }
    return ftruncate(fd, size);
}

int
CPython_BeginFileCheckpoint(void)
{
    if (files == NULL) {
        return 0;
    }
    for (size_t i = 0; i < files->count; ++i) {
        Descriptor *entry = &files->descriptors[i];
        entry->offset = lseek(entry->fd, 0, SEEK_CUR);
        if (entry->offset < 0) {
            return -1;
        }
    }
    files->checkpoint_count = files->count;
    files->checkpoint = true;
    return 0;
}

void
CPython_FinishFileCheckpoint(bool restoring)
{
    if (files == NULL || !files->checkpoint) {
        return;
    }

    size_t remaining = 0;
    for (size_t i = 0; i < files->count; ++i) {
        Descriptor entry = files->descriptors[i];
        if (restoring ? i >= files->checkpoint_count : entry.closed) {
            close(entry.fd);
            continue;
        }
        if (restoring) {
            (void)lseek(entry.fd, entry.offset, SEEK_SET);
            entry.closed = false;
        }
        files->descriptors[remaining++] = entry;
    }
    files->count = remaining;
    files->checkpoint = false;
}

static int
reserve_descriptor(void)
{
    if (files->count < files->capacity) {
        return 0;
    }
    size_t capacity = files->capacity == 0 ? 16 : files->capacity * 2;
    if (capacity > SIZE_MAX / sizeof(Descriptor)) {
        PyErr_NoMemory();
        return -1;
    }
    Descriptor *descriptors = realloc(files->descriptors, capacity * sizeof(Descriptor));
    if (descriptors == NULL) {
        PyErr_NoMemory();
        return -1;
    }
    files->descriptors = descriptors;
    files->capacity = capacity;
    return 0;
}

CPython_FileTarget *
CPython_CheckFile(const char *path, int base, int flags, CPython_FileOperation operation,
                  PyObject *filename)
{
    if (path[0] != '/' && base != AT_FDCWD && CPython_RequireFileDescriptor(base, false) < 0) {
        PyErr_SetFromErrnoWithFilenameObject(PyExc_OSError, filename);
        return NULL;
    }

    bool follow = !(flags & O_NOFOLLOW) && (flags & (O_CREAT | O_EXCL)) != (O_CREAT | O_EXCL);
    CPython_FileTarget *target;
    Py_BEGIN_ALLOW_THREADS target = CPython_PinFileTarget(path, base, follow);
    Py_END_ALLOW_THREADS if (target == NULL)
    {
        PyErr_SetFromErrnoWithFilenameObject(PyExc_OSError, filename);
        return NULL;
    }
    int decision = check_file == NULL ? 0
                                      : check_file(check_context, CPython_FileTargetPath(target),
                                                   flags & O_ACCMODE, flags & ~O_ACCMODE, operation,
                                                   CPython_FileTargetExists(target));
    if (decision > 0) {
        return target;
    }
    CPython_FreeFileTarget(target);
    if (decision == 0) {
        errno = EACCES;
        PyErr_SetFromErrnoWithFilenameObject(PyExc_PermissionError, filename);
    }
    return NULL;
}

int
CPython_OpenFile(const char *path, int base, int flags, mode_t mode, PyObject *filename)
{
    int fd;
    if (files == NULL) {
        Py_BEGIN_ALLOW_THREADS fd = openat(base, path, flags, mode);
        Py_END_ALLOW_THREADS return fd;
    }

    CPython_FileTarget *target = CPython_CheckFile(path, base, flags, CPython_FileOpen, filename);
    if (target == NULL) {
        return -1;
    }
    if (reserve_descriptor() < 0) {
        CPython_FreeFileTarget(target);
        return -1;
    }

    Py_BEGIN_ALLOW_THREADS fd = CPython_OpenFileTarget(target, flags, mode);
    CPython_FreeFileTarget(target);
    Py_END_ALLOW_THREADS if (fd >= 0)
    {
        files->descriptors[files->count++] = (Descriptor){.fd = fd};
    }
    return fd;
}

#include "../file_open.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct {
    int fd;

    uint64_t pipe;
} Descriptor;

struct CPython_Files {
    Descriptor *descriptors;
    size_t count;
    size_t capacity;

    uint64_t next_pipe;
};

static _Thread_local CPython_FileAccessCheck check_file;
static _Thread_local void *check_context;

static _Thread_local CPython_Files *files;
static _Thread_local int streams[3] = {-1, -1, -1};

CPython_Files *
CPython_NewFiles(void)
{
    return calloc(1, sizeof(CPython_Files));
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

CPython_FileAccessState
CPython_CurrentFileAccess(void)
{
    return (CPython_FileAccessState){
        .check = check_file,
        .context = check_context,
        .files = files,

        .input = streams[0],
        .output = streams[1],
        .error = streams[2],
    };
}

bool
CPython_RestrictedFiles(void)
{
    return files != NULL;
}

void
CPython_SetStreamDescriptors(int input, int output, int error)
{
    streams[0] = input;
    streams[1] = output;
    streams[2] = error;
}

static bool
is_stream(int fd)
{
    return fd >= 0 && (fd == streams[0] || fd == streams[1] || fd == streams[2]);
}

static Descriptor *
require_descriptor(int fd)
{
    for (size_t i = 0; i < files->count; ++i) {
        Descriptor *entry = &files->descriptors[i];
        if (entry->fd == fd) {
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

static int
reserve_descriptors(size_t additional)
{
    if (additional <= files->capacity - files->count) {
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

static inline void
track_reserved_descriptor(int fd, uint64_t pipe)
{
    files->descriptors[files->count++] = (Descriptor){.fd = fd, .pipe = pipe};
}

int
CPython_TrackPipe(int reader, int writer)
{
    if (files == NULL) {
        return 0;
    }
    if (reserve_descriptors(2) < 0) {
        return -1;
    }

    uint64_t identity = ++files->next_pipe;
    track_reserved_descriptor(reader, identity);
    track_reserved_descriptor(writer, identity);
    return 0;
}

uint64_t
CPython_PipeIdentity(int fd)
{
    if (files == NULL || fd < 0) {
        return 0;
    }
    Descriptor *entry = require_descriptor(fd);
    return entry == NULL ? 0 : entry->pipe;
}

bool
CPython_HasOpenPipe(const CPython_Files *state, uint64_t identity)
{
    if (identity == 0) {
        return false;
    }
    for (size_t i = 0; i < state->count; ++i) {
        if (state->descriptors[i].pipe == identity) {
            return true;
        }
    }
    return false;
}

int
CPython_DuplicateFileDescriptor(int fd)
{
    Descriptor *source = require_descriptor(fd);
    if (source == NULL) {
        PyErr_SetFromErrno(PyExc_OSError);
        return -1;
    }

    // Reserving space may move the table.
    uint64_t identity = source->pipe;
    if (reserve_descriptors(1) < 0) {
        return -1;
    }

    int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (duplicate < 0) {
        PyErr_SetFromErrno(PyExc_OSError);
        return -1;
    }
    track_reserved_descriptor(duplicate, identity);
    return duplicate;
}

static CPython_FileTarget *
authorize_target(CPython_FileTarget *target, int flags, CPython_FileOperation operation,
                 PyObject *filename)
{
    int decision = 0;
    if (check_file != NULL) {
        decision = check_file(check_context, CPython_FileTargetPath(target), flags & O_ACCMODE,
                              flags & ~O_ACCMODE, operation, CPython_FileTargetExists(target));
    }
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

CPython_FileTarget *
CPython_CheckFile(const char *path, int base, int flags, CPython_FileOperation operation,
                  PyObject *filename)
{
    if (path[0] != '/' && base != AT_FDCWD && CPython_RequireFileDescriptor(base, false) < 0) {
        PyErr_SetFromErrnoWithFilenameObject(PyExc_OSError, filename);
        return NULL;
    }

    bool follow = !(flags & O_NOFOLLOW) && (flags & (O_CREAT | O_EXCL)) != (O_CREAT | O_EXCL);
    PyThreadState *state = PyEval_SaveThread();
    CPython_FileTarget *target = CPython_PinFileTarget(path, base, follow);
    PyEval_RestoreThread(state);
    if (target == NULL) {
        PyErr_SetFromErrnoWithFilenameObject(PyExc_OSError, filename);
        return NULL;
    }

    return authorize_target(target, flags, operation, filename);
}

int
CPython_OpenFile(const char *path, int base, int flags, mode_t mode, PyObject *filename)
{
    if (files == NULL) {
        PyThreadState *state = PyEval_SaveThread();
        int fd = openat(base, path, flags, mode);
        PyEval_RestoreThread(state);
        return fd;
    }

    CPython_FileTarget *target = CPython_CheckFile(path, base, flags, CPython_FileOpen, filename);
    if (target == NULL) {
        return -1;
    }
    if (reserve_descriptors(1) < 0) {
        CPython_FreeFileTarget(target);
        return -1;
    }

    PyThreadState *state = PyEval_SaveThread();
    int fd = CPython_OpenFileTarget(target, flags, mode);
    CPython_FreeFileTarget(target);
    PyEval_RestoreThread(state);

    if (fd >= 0) {
        track_reserved_descriptor(fd, 0);
    }
    return fd;
}

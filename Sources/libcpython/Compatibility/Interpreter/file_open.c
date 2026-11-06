#include "../file_open.h"
#include "../interpreter.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    CPython_FileOpenCheck check;
    void *context;
} FileOpenHook;

static _Thread_local FileOpenHook file_open_hook;

void
CPython_SetFileOpenCheck(CPython_FileOpenCheck check, void *context)
{
    file_open_hook = (FileOpenHook){.check = check, .context = context};
}

static int
descriptor_path(int fd, char *path)
{
#if defined(F_GETPATH)
    return fcntl(fd, F_GETPATH, path);
#elif defined(__linux__)
    char link_path[48];
    snprintf(link_path, sizeof(link_path), "/proc/self/fd/%d", fd);
    ssize_t length = readlink(link_path, path, PATH_MAX);
    if (length < 0) {
        return -1;
    }
    if (length == PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    path[length] = '\0';
    return 0;
#else
    (void)fd;
    (void)path;
    errno = ENOTSUP;
    return -1;
#endif
}

static int
directory_path(int dir_fd, char *path)
{
    if (dir_fd == AT_FDCWD) {
        return getcwd(path, PATH_MAX) == NULL ? -1 : 0;
    }

    struct stat info;
    if (fstat(dir_fd, &info) < 0) {
        return -1;
    }

    if (!S_ISDIR(info.st_mode)) {
        errno = ENOTDIR;
        return -1;
    }
    if (info.st_nlink == 0) {
        errno = ENOENT;
        return -1;
    }
    return descriptor_path(dir_fd, path);
}

static char *
join_path(const char *directory, const char *path)
{
    size_t directory_length = strlen(directory);
    size_t path_size = strlen(path) + 1;
    char *absolute = PyMem_Malloc(directory_length + path_size + 1);
    if (absolute == NULL) {
        PyErr_NoMemory();
        return NULL;
    }

    memcpy(absolute, directory, directory_length);
    if (absolute[directory_length - 1] != '/') {
        absolute[directory_length++] = '/';
    }
    memcpy(absolute + directory_length, path, path_size);
    return absolute;
}

static char *
resolve_relative_path(const char *path, int dir_fd, PyObject *filename)
{
    char directory[PATH_MAX];
    if (directory_path(dir_fd, directory) < 0) {
        PyErr_SetFromErrnoWithFilenameObject(PyExc_OSError, filename);
        return NULL;
    }
    if (directory[0] != '/') {
        PyErr_SetString(PyExc_OSError, "The file's base directory has no absolute path.");
        return NULL;
    }
    return join_path(directory, path);
}

int
CPython_CheckFileOpen(const char *path, int dir_fd, int flags, PyObject *filename,
                      char **replacement)
{
    *replacement = NULL;
    if (file_open_hook.check == NULL || path[0] == '\0') {
        return 0;
    }

    char *absolute = NULL;
    if (path[0] != '/') {
        absolute = resolve_relative_path(path, dir_fd, filename);
        if (absolute == NULL) {
            return -1;
        }
    }

    const char *checked_path = absolute != NULL ? absolute : path;
    int access_mode = flags & O_ACCMODE;
    int options = flags & ~O_ACCMODE;
    int decision = file_open_hook.check(file_open_hook.context, checked_path, access_mode, options);

    if (decision > 0 && dir_fd == AT_FDCWD) {
        /* Preserve the working directory used to resolve the delegate's path. */
        *replacement = absolute;
        return 0;
    }

    PyMem_Free(absolute);
    if (decision == 0) {
        errno = EACCES;
        PyErr_SetFromErrnoWithFilenameObject(PyExc_PermissionError, filename);
    }
    return decision > 0 ? 0 : -1;
}

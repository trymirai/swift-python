#include "../file_open.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct CPython_FileTarget {
    int parent;

    struct stat identity;
    bool exists;

    char path[PATH_MAX];
    char name[NAME_MAX + 1];
};

static int
terminate_link_path(char path[PATH_MAX], ssize_t count)
{
    if (count < 0) {
        return -1;
    }
    if (count == PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    path[count] = '\0';
    return 0;
}

static int
descriptor_path(int fd, char path[PATH_MAX])
{
#if defined(F_GETPATH)
    return fcntl(fd, F_GETPATH, path);
#elif defined(__linux__)
    char link[48];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    return terminate_link_path(path, readlink(link, path, PATH_MAX));
#else
    errno = ENOTSUP;
    return -1;
#endif
}

static int
join(char result[PATH_MAX], const char *parent, const char *name)
{
    const char *separator = strcmp(parent, "/") == 0 ? "" : "/";
    if (snprintf(result, PATH_MAX, "%s%s%s", parent, separator, name) >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

static bool
same_object(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
           (a->st_mode & S_IFMT) == (b->st_mode & S_IFMT);
}

static int
open_directory(int base, const char *path)
{
#ifdef O_PATH
    return openat(base, path, O_PATH | O_DIRECTORY | O_CLOEXEC);
#elif defined(O_SEARCH)
    return openat(base, path, O_SEARCH | O_DIRECTORY | O_CLOEXEC);
#else
    return openat(base, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
#endif
}

static const char *
split_candidate(char *candidate, char name[NAME_MAX + 1])
{
    char *slash = strrchr(candidate, '/');
    const char *tail = slash == NULL ? candidate : slash + 1;
    size_t length = strlen(tail);

    if (length > NAME_MAX) {
        errno = ENAMETOOLONG;
        return NULL;
    }

    if (length == 0 || strcmp(tail, ".") == 0 || strcmp(tail, "..") == 0) {
        memcpy(name, ".", 2);
        return candidate;
    }

    memcpy(name, tail, length + 1);
    if (slash == NULL) {
        return ".";
    }
    if (slash == candidate) {
        return "/";
    }
    *slash = '\0';
    return candidate;
}

static int
set_display_path(CPython_FileTarget *target)
{
    int parent = target->parent;
    char display[PATH_MAX];
    struct stat pinned;
    struct stat visible;
    if (descriptor_path(parent, display) < 0 || fstat(parent, &pinned) < 0 ||
        stat(display, &visible) < 0) {
        return -1;
    }

    // The delegate sees the path, so it must name the directory held by the descriptor.
    if (!same_object(&pinned, &visible)) {
        errno = ESTALE;
        return -1;
    }
    if (strcmp(target->name, ".") != 0) {
        return join(target->path, display, target->name);
    }
    memcpy(target->path, display, strlen(display) + 1);
    return 0;
}

static int
pin_parent(CPython_FileTarget *target, int base, const char *directory)
{
    // Resolve relative link targets before releasing the previous parent descriptor.
    int parent = open_directory(base, directory);
    if (parent < 0) {
        return -1;
    }
    if (target->parent >= 0) {
        close(target->parent);
    }
    target->parent = parent;
    return set_display_path(target);
}

void
CPython_FreeFileTarget(CPython_FileTarget *target)
{
    int error = errno;
    if (target != NULL) {
        if (target->parent >= 0) {
            close(target->parent);
        }
        free(target);
    }
    errno = error;
}

static bool
strip_trailing_slashes(char path[PATH_MAX])
{
    size_t length = strlen(path);
    bool stripped = false;
    while (length > 1 && path[length - 1] == '/') {
        path[--length] = '\0';
        stripped = true;
    }
    return stripped;
}

static int
pin_candidate(CPython_FileTarget *target, char candidate[PATH_MAX], int base, bool needs_directory)
{
    const char *directory = split_candidate(candidate, target->name);
    if (directory == NULL || pin_parent(target, base, directory) < 0) {
        return -1;
    }

    if (fstatat(target->parent, target->name, &target->identity, AT_SYMLINK_NOFOLLOW) == 0) {
        target->exists = true;
        return 0;
    }
    if (errno == ENOENT && !needs_directory) {
        target->exists = false;
        return 0;
    }
    return -1;
}

static int
resolve_candidate(CPython_FileTarget *target, char candidate[PATH_MAX], int base, bool follow,
                  bool needs_directory)
{
    for (int links = 0; links <= 40; ++links) {
        if (strip_trailing_slashes(candidate)) {
            needs_directory = true;
        }
        if (pin_candidate(target, candidate, base, needs_directory) < 0) {
            return -1;
        }
        if (!target->exists) {
            return 0;
        }

        if (!follow || !S_ISLNK(target->identity.st_mode)) {
            if (needs_directory && !S_ISDIR(target->identity.st_mode)) {
                errno = ENOTDIR;
                return -1;
            }
            return 0;
        }

        ssize_t count = readlinkat(target->parent, target->name, candidate, PATH_MAX);
        if (terminate_link_path(candidate, count) < 0) {
            return -1;
        }
        base = target->parent;
        errno = ELOOP;
    }
    return -1;
}

CPython_FileTarget *
CPython_PinFileTarget(const char *path, int base, bool follow)
{
    if (*path == '\0') {
        errno = ENOENT;
        return NULL;
    }

    char candidate[PATH_MAX];
    size_t size = strlen(path) + 1;
    if (size > sizeof(candidate)) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    memcpy(candidate, path, size);

    CPython_FileTarget *target = calloc(1, sizeof(*target));
    if (target == NULL) {
        return NULL;
    }
    target->parent = -1;

    bool needs_directory = path[size - 2] == '/';
    if (resolve_candidate(target, candidate, base, follow, needs_directory) == 0) {
        return target;
    }
    CPython_FreeFileTarget(target);
    return NULL;
}

const char *
CPython_FileTargetPath(const CPython_FileTarget *target)
{
    return target->path;
}

bool
CPython_FileTargetExists(const CPython_FileTarget *target)
{
    return target->exists;
}

static int
validate(const CPython_FileTarget *target, struct stat *info)
{
    if (fstatat(target->parent, target->name, info, AT_SYMLINK_NOFOLLOW) < 0) {
        return !target->exists && errno == ENOENT ? 0 : -1;
    }
    if (!target->exists || !same_object(info, &target->identity)) {
        errno = ESTALE;
        return -1;
    }
    return 0;
}

static int
finish_open(const CPython_FileTarget *target, int fd, int flags)
{
    struct stat info;
    if (fstat(fd, &info) < 0) {
        return -1;
    }
    if (target->exists && !same_object(&info, &target->identity)) {
        errno = ESTALE;
        return -1;
    }

    if (!(flags & O_NONBLOCK) && fcntl(fd, F_SETFL, flags & ~O_TRUNC) < 0) {
        return -1;
    }
    // Apply truncation after verifying that openat reached the authorized entry.
    return flags & O_TRUNC ? ftruncate(fd, 0) : 0;
}

static int
validate_open(const CPython_FileTarget *target, int flags)
{
    if (target->exists && (flags & (O_CREAT | O_EXCL)) == (O_CREAT | O_EXCL)) {
        errno = EEXIST;
        return -1;
    }
    if (!target->exists && !(flags & O_CREAT)) {
        errno = ENOENT;
        return -1;
    }
    if (target->exists && !S_ISREG(target->identity.st_mode) &&
        !S_ISDIR(target->identity.st_mode)) {
        errno = S_ISLNK(target->identity.st_mode) ? ELOOP : EACCES;
        return -1;
    }
    return 0;
}

int
CPython_OpenFileTarget(const CPython_FileTarget *target, int flags, mode_t mode)
{
    if (validate_open(target, flags) < 0) {
        return -1;
    }

    // Nonblocking open protects against a FIFO replacing the entry before the identity check.
    int options = (flags & ~(O_CREAT | O_EXCL | O_TRUNC)) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
    if (!target->exists) {
        options |= O_CREAT | O_EXCL;
    }
    int fd = openat(target->parent, target->name, options, mode);
    if (fd < 0) {
        return -1;
    }

    if (finish_open(target, fd, flags) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    return fd;
}

int
CPython_AccessFileTarget(const CPython_FileTarget *target, int mode, bool effective)
{
    struct stat info;
    if (validate(target, &info) < 0) {
        return -1;
    }
    return faccessat(target->parent, target->name, mode,
                     AT_SYMLINK_NOFOLLOW | (effective ? AT_EACCESS : 0));
}

int
CPython_StatFileTarget(const CPython_FileTarget *target, struct stat *info)
{
    if (!target->exists) {
        errno = ENOENT;
        return -1;
    }
    return validate(target, info);
}

int
CPython_UnlinkFileTarget(const CPython_FileTarget *target, int flags)
{
    struct stat info;
    return validate(target, &info) < 0 ? -1 : unlinkat(target->parent, target->name, flags);
}

int
CPython_MakeDirectoryTarget(const CPython_FileTarget *target, mode_t mode)
{
    return mkdirat(target->parent, target->name, mode);
}

int
CPython_RenameFileTarget(const CPython_FileTarget *source, const CPython_FileTarget *destination)
{
    struct stat info;
    if (validate(source, &info) < 0 || validate(destination, &info) < 0) {
        return -1;
    }
    return renameat(source->parent, source->name, destination->parent, destination->name);
}

ssize_t
CPython_ReadLinkTarget(const CPython_FileTarget *target, char *value, size_t capacity)
{
    struct stat info;
    if (validate(target, &info) < 0) {
        return -1;
    }
    return readlinkat(target->parent, target->name, value, capacity);
}

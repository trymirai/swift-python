/* Included after posixmodule.c's path conversion and stat helpers. */
static int
swift_open_directory(path_t *path)
{
    if (path->is_fd) {
        if (CPython_RequireFileDescriptor(path->fd, false) < 0) {
            path_error(path);
            return -1;
        }
        // Open a new directory stream, with an independent position.
        int fd = openat(path->fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd < 0) {
            path_error(path);
        }
        return fd;
    }
    CPython_FileTarget *target =
        CPython_CheckFile(path->narrow ? path->narrow : ".", DEFAULT_DIR_FD, O_RDONLY,
                          CPython_FileEnumerate, path->object ? path->object : Py_None);
    if (target == NULL) {
        return -1;
    }
    int fd = CPython_OpenFileTarget(target, O_RDONLY | O_DIRECTORY, 0);
    CPython_FreeFileTarget(target);
    if (fd < 0) {
        path_error(path);
    }
    return fd;
}

static PyObject *
swift_stat(PyObject *module, const char *name, int base, int follow, PyObject *original)
{
    CPython_FileTarget *target =
        CPython_CheckFile(name, base, follow ? 0 : O_NOFOLLOW, CPython_FileMetadata, original);
    if (target == NULL) {
        return NULL;
    }
    STRUCT_STAT st;
    int result = CPython_StatFileTarget(target, &st);
    CPython_FreeFileTarget(target);
    if (result < 0) {
        return PyErr_SetFromErrnoWithFilenameObject(PyExc_OSError, original);
    }
    return _pystat_fromstructstat(module, &st);
}

static inline CPython_FileTarget *
swift_check_mutation(path_t *path, int base, CPython_FileOperation operation)
{
    return CPython_CheckFile(path->narrow, base, O_WRONLY | O_NOFOLLOW, operation, path->object);
}

static PyObject *
swift_remove(path_t *path, int base, int flags)
{
    CPython_FileTarget *target = swift_check_mutation(path, base, CPython_FileRemove);
    if (target == NULL) {
        return NULL;
    }
    int result = CPython_UnlinkFileTarget(target, flags);
    CPython_FreeFileTarget(target);
    if (result < 0) {
        return path_error(path);
    }
    Py_RETURN_NONE;
}

static PyObject *
swift_rename(path_t *source, path_t *destination, int source_base, int destination_base)
{
    CPython_FileTarget *from = swift_check_mutation(source, source_base, CPython_FileRenameSource);
    if (from == NULL) {
        return NULL;
    }
    CPython_FileTarget *to =
        swift_check_mutation(destination, destination_base, CPython_FileRenameDestination);
    if (to == NULL) {
        CPython_FreeFileTarget(from);
        return NULL;
    }

    int result = CPython_RenameFileTarget(from, to);
    CPython_FreeFileTarget(from);
    CPython_FreeFileTarget(to);
    if (result < 0) {
        return path_error2(source, destination);
    }
    Py_RETURN_NONE;
}

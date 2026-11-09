#include "../file_open.h"

#include <string.h>

static bool
listed(const char *name, const char *const list[])
{
    for (size_t i = 0; list[i] != NULL; ++i) {
        if (strcmp(name, list[i]) == 0) {
            return true;
        }
    }
    return false;
}

PyObject *
CPython_UnsupportedNativeOperation(void)
{
    PyErr_SetString(PyExc_PermissionError, "Native operation is unavailable in a restricted Python session.");
    return NULL;
}

int
CPython_AllowBuiltin(PyObject *name)
{
    if (!CPython_RestrictedFiles()) {
        return 0;
    }

    // Review file operations and checkpoint ownership before allowing another native module.
    // Native code can bypass both the file hooks and the Python allocators.
    static const char *const allowed[] = {
        "_abc", "_ast", "_asyncio", "_bisect", "_blake2", "_codecs",
        "_codecs_cn", "_codecs_hk", "_codecs_iso2022", "_codecs_jp", "_codecs_kr",
        "_codecs_tw", "_collections", "_contextvars", "_csv", "_datetime",
        "_functools", "_heapq", "_imp", "_io", "_json", "_locale", "_math_integer",
        "_md5", "_multibytecodec", "_opcode", "_operator", "_pickle", "_posixsubprocess",
        "_queue", "_random", "_scproxy", "_sha1", "_sha2", "_sha3", "_signal", "_socket", "_sre",
        "_stat", "_string", "_struct", "_suggestions", "_swift_python", "_symtable",
        "_sysconfig", "_thread", "_tokenize", "_types", "_typing", "_warnings", "_weakref",
        "array", "atexit", "binascii", "builtins", "cmath", "errno", "gc", "itertools",
        "marshal", "math", "posix", "select", "sys", "time", "unicodedata", "zlib", NULL,
    };

    const char *value = PyUnicode_AsUTF8(name);
    if (value == NULL) {
        return -1;
    }
    if (!listed(value, allowed)) {
        PyErr_Format(PyExc_ModuleNotFoundError, "Native module %R is unavailable in a restricted Python session.", name);
        return -1;
    }
    return 0;
}

int
CPython_RestrictPOSIXModule(PyObject *module)
{
    if (!CPython_RestrictedFiles()) {
        return 0;
    }

    static const char *const allowed[] = {
        "_create_environ", "_path_normpath", "_path_splitroot_ex",
        // tempfile needs the chmod entry point. The POSIX patch denies the mutation.
        "access", "chmod", "close", "cpu_count", "fspath", "fstat", "ftruncate", "getcwd", "getcwdb",
        "getegid", "geteuid", "getgid", "getgroups", "getpid", "getppid", "getuid",
        "isatty", "listdir", "lseek", "lstat", "mkdir", "open", "read", "readlink",
        "remove", "rename", "replace", "rmdir", "scandir", "stat", "strerror", "sysconf", "truncate",
        "uname", "unlink", "urandom", "waitpid", "waitstatus_to_exitcode", "write",
        "WCOREDUMP", "WEXITSTATUS", "WIFCONTINUED", "WIFEXITED", "WIFSIGNALED",
        "WIFSTOPPED", "WSTOPSIG", "WTERMSIG", NULL,
    };
    PyObject *dict = PyModule_GetDict(module);
    PyObject *keys = PyDict_Keys(dict);
    if (keys == NULL) {
        return -1;
    }
    int result = 0;
    for (Py_ssize_t i = 0; i < PyList_GET_SIZE(keys); ++i) {
        PyObject *key = PyList_GET_ITEM(keys, i);
        PyObject *value = PyDict_GetItemWithError(dict, key);
        if (value == NULL || !PyCFunction_Check(value)) {
            continue;
        }
        const char *name = PyUnicode_AsUTF8(key);
        if (name == NULL || (!listed(name, allowed) && PyDict_DelItem(dict, key) < 0)) {
            result = -1;
            break;
        }
    }
    Py_DECREF(keys);
    return result;
}

static int
audit_file_access(const char *event, PyObject *args, void *context)
{
    (void)args;
    (void)context;
    if (!CPython_RestrictedFiles()) {
        return 0;
    }

    // These modules are imported by asyncio. Their process and socket entry
    // points remain unavailable, including calls via private native functions.
    if (strncmp(event, "socket.", 7) == 0 ||
        strcmp(event, "_posixsubprocess.fork_exec") == 0 ||
        strcmp(event, "sys.addaudithook") == 0) {
        CPython_UnsupportedNativeOperation();
        return -1;
    }
    return 0;
}

int
CPython_InstallFileAudit(void)
{
    return PySys_AddAuditHook(audit_file_access, NULL);
}

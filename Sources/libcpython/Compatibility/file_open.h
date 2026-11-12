#ifndef SWIFT_PYTHON_LIBCPYTHON_FILE_OPEN_H
#define SWIFT_PYTHON_LIBCPYTHON_FILE_OPEN_H

#include "Python.h"
#include <dirent.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/stat.h>

typedef struct CPython_FileTarget CPython_FileTarget;

// The target retains its parent descriptor across the access decision. The caller frees it.
CPython_FileTarget *_Nullable CPython_PinFileTarget(const char *_Nonnull path, int base,
                                                    bool follow);
void CPython_FreeFileTarget(CPython_FileTarget *_Nullable target);

// The returned path is borrowed from the target.
const char *_Nonnull CPython_FileTargetPath(const CPython_FileTarget *_Nonnull target);
bool CPython_FileTargetExists(const CPython_FileTarget *_Nonnull target);

int CPython_OpenFileTarget(const CPython_FileTarget *_Nonnull target, int flags, mode_t mode);
int CPython_AccessFileTarget(const CPython_FileTarget *_Nonnull target, int mode, bool effective);
int CPython_StatFileTarget(const CPython_FileTarget *_Nonnull target, struct stat *_Nonnull info);
int CPython_UnlinkFileTarget(const CPython_FileTarget *_Nonnull target, int flags);
int CPython_MakeDirectoryTarget(const CPython_FileTarget *_Nonnull target, mode_t mode);
int CPython_RenameFileTarget(const CPython_FileTarget *_Nonnull source,
                             const CPython_FileTarget *_Nonnull destination);
ssize_t CPython_ReadLinkTarget(const CPython_FileTarget *_Nonnull target, char *_Nonnull value,
                               size_t capacity);

typedef enum {
    CPython_FileOpen,
    CPython_FileMetadata,
    CPython_FileEnumerate,
    CPython_FileCreateDirectory,
    CPython_FileRemove,
    CPython_FileRenameSource,
    CPython_FileRenameDestination,
} CPython_FileOperation;

typedef struct CPython_Files CPython_Files;

// Return a positive value to allow, zero to deny, or -1 with a Python exception set.
typedef int (*CPython_FileAccessCheck)(void *_Nonnull context, const char *_Nonnull path, int mode,
                                       int options, CPython_FileOperation operation, bool exists);

typedef struct {
    CPython_FileAccessCheck _Nullable check;
    void *_Nullable context;
    CPython_Files *_Nullable files;

    int input;
    int output;
    int error;
} CPython_FileAccessState;

CPython_Files *_Nullable CPython_NewFiles(void);
void CPython_FreeFiles(CPython_Files *_Nullable files);

CPython_FileAccessState CPython_CurrentFileAccess(void);
void CPython_SetFileAccessCheck(CPython_FileAccessCheck _Nullable check, void *_Nullable context,
                                CPython_Files *_Nullable files);

bool CPython_RestrictedFiles(void);
int CPython_RestrictPOSIXModule(PyObject *_Nonnull module);
int CPython_AllowBuiltin(PyObject *_Nonnull name);
int CPython_InstallFileAudit(void);
PyObject *_Nullable CPython_UnsupportedNativeOperation(void);

// The host owns these descriptors and keeps them open until execution finishes.
void CPython_SetStreamDescriptors(int input, int output, int error);

int CPython_OpenFile(const char *_Nonnull path, int base, int flags, mode_t mode,
                     PyObject *_Nonnull filename);
CPython_FileTarget *_Nullable CPython_CheckFile(const char *_Nonnull path, int base, int flags,
                                                CPython_FileOperation operation,
                                                PyObject *_Nonnull filename);

int CPython_RequireFileDescriptor(int fd, bool borrowing_stream);
int CPython_CloseFileDescriptor(int fd);
int CPython_TruncateFileDescriptor(int fd, off_t size);

int CPython_TrackPipe(int reader, int writer);
int CPython_DuplicateFileDescriptor(int fd);
uint64_t CPython_PipeIdentity(int fd);
bool CPython_HasOpenPipe(const CPython_Files *_Nonnull files, uint64_t identity);

typedef struct CPython_Subprocesses CPython_Subprocesses;
typedef struct CPython_Subprocess CPython_Subprocess;

CPython_Subprocesses *_Nullable CPython_NewSubprocesses(void);
void CPython_FreeSubprocesses(CPython_Subprocesses *_Nonnull scope);
void CPython_SetSubprocesses(CPython_Subprocesses *_Nullable scope);
CPython_Subprocesses *_Nullable CPython_CurrentSubprocesses(void);
bool CPython_AllowsSubprocesses(void);
void CPython_StopSubprocesses(CPython_Subprocesses *_Nonnull scope);
int CPython_JoinSubprocesses(CPython_Subprocesses *_Nonnull scope);
bool CPython_SubprocessesHaveOpenPipes(CPython_Subprocesses *_Nonnull scope,
                                       const CPython_Files *_Nonnull files);

CPython_Subprocess *_Nullable CPython_PrepareSubprocess(int input, int output, int error);
void CPython_RegisterSubprocess(CPython_Subprocess *_Nonnull process, pid_t pid);
pid_t CPython_WaitSubprocess(pid_t pid, int *_Nonnull status, int options);
int CPython_SignalSubprocess(pid_t pid, int signal);

#endif /* SWIFT_PYTHON_LIBCPYTHON_FILE_OPEN_H */

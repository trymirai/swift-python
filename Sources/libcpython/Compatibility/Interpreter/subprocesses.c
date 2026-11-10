#include "../interpreter.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

struct CPython_Subprocess {
    pid_t pid;
    uint64_t pipes[3];

    CPython_Subprocess *next;
};

struct CPython_Subprocesses {
    pthread_mutex_t lock;

    CPython_Subprocess *children;
    bool stopping;
};

static _Thread_local CPython_Subprocesses *current;

// The interpreter thread alone admits and reaps children. The interruption
// thread can signal them while the interpreter is blocked in read or waitid.
CPython_Subprocesses *
CPython_NewSubprocesses(void)
{
    CPython_Subprocesses *scope = calloc(1, sizeof(*scope));
    if (scope != NULL && pthread_mutex_init(&scope->lock, NULL) != 0) {
        free(scope);
        return NULL;
    }
    return scope;
}

void
CPython_SetSubprocesses(CPython_Subprocesses *scope)
{
    current = scope;
}

bool
CPython_AllowsSubprocesses(void)
{
    return current != NULL;
}

static void
stop_child(pid_t pid)
{
    // The child may still be setting up its group when Stop wins the launch race.
    (void)kill(pid, SIGKILL);
    (void)kill(-pid, SIGKILL);
}

void
CPython_StopSubprocesses(CPython_Subprocesses *scope)
{
    pthread_mutex_lock(&scope->lock);
    if (!scope->stopping) {
        scope->stopping = true;
        for (CPython_Subprocess *child = scope->children; child != NULL; child = child->next) {
            stop_child(child->pid);
        }
    }
    pthread_mutex_unlock(&scope->lock);
}

CPython_Subprocess *
CPython_PrepareSubprocess(int input, int output, int error)
{
    if (current == NULL) {
        CPython_UnsupportedNativeOperation();
        return NULL;
    }

    pthread_mutex_lock(&current->lock);
    bool stopping = current->stopping;
    pthread_mutex_unlock(&current->lock);
    if (stopping) {
        CPython_RaiseKeyboardInterrupt();
        return NULL;
    }

    // Allocate before spawning so a successful fork always has an owner.
    CPython_Subprocess *child = calloc(1, sizeof(*child));
    if (child == NULL) {
        PyErr_NoMemory();
        return NULL;
    }

    child->pipes[0] = CPython_PipeIdentity(input);
    child->pipes[1] = CPython_PipeIdentity(output);
    child->pipes[2] = CPython_PipeIdentity(error);
    return child;
}

void
CPython_RegisterSubprocess(CPython_Subprocess *child, pid_t pid)
{
    if (pid <= 0) {
        free(child);
        return;
    }

    pthread_mutex_lock(&current->lock);
    child->pid = pid;
    child->next = current->children;
    current->children = child;
    if (current->stopping) {
        stop_child(pid);
    }
    pthread_mutex_unlock(&current->lock);
}

static CPython_Subprocess **
find_child(CPython_Subprocesses *scope, pid_t pid)
{
    CPython_Subprocess **entry = &scope->children;
    while (*entry != NULL && (*entry)->pid != pid) {
        entry = &(*entry)->next;
    }
    return entry;
}

static void
remove_child(CPython_Subprocess **entry)
{
    CPython_Subprocess *child = *entry;
    *entry = child->next;
    free(child);
}

static void
forget_child(CPython_Subprocesses *scope, pid_t pid)
{
    pthread_mutex_lock(&scope->lock);
    remove_child(find_child(scope, pid));
    pthread_mutex_unlock(&scope->lock);
}

int
CPython_SignalSubprocess(pid_t pid, int signal)
{
    if (current == NULL) {
        errno = EPERM;
        return -1;
    }

    pthread_mutex_lock(&current->lock);
    bool owned = *find_child(current, pid) != NULL;
    int result = owned ? kill(pid, signal) : -1;
    int error = owned ? errno : EPERM;
    pthread_mutex_unlock(&current->lock);
    errno = error;
    return result;
}

static int
peek_child(pid_t pid, int options, siginfo_t *info)
{
    *info = (siginfo_t){0};
    return waitid(P_PID, (id_t)pid, info, WEXITED | WNOWAIT | options);
}

static pid_t
reap_exited_child(CPython_Subprocesses *scope, pid_t pid, int *status)
{
    pthread_mutex_lock(&scope->lock);
    (void)kill(-pid, SIGKILL);
    pid_t result = waitpid(pid, status, WNOHANG);
    int error = errno;
    if (result > 0 || (result < 0 && error == ECHILD)) {
        remove_child(find_child(scope, pid));
    }
    pthread_mutex_unlock(&scope->lock);
    errno = error;
    return result;
}

static pid_t
wait_for_child(CPython_Subprocesses *scope, pid_t pid, int *status, int options)
{
    // WNOWAIT holds the leader's PID until the final group signal and reap.
    // Waiting here leaves the lock available to the interruption thread.
    siginfo_t info;
    if (peek_child(pid, options, &info) < 0) {
        int error = errno;
        if (error == ECHILD) {
            forget_child(scope, pid);
        }
        errno = error;
        return -1;
    }

    return info.si_pid == 0 ? 0 : reap_exited_child(scope, pid, status);
}

pid_t
CPython_WaitSubprocess(pid_t pid, int *status, int options)
{
    if ((options & ~WNOHANG) != 0) {
        errno = EINVAL;
        return -1;
    }
    if (current == NULL || *find_child(current, pid) == NULL) {
        errno = EPERM;
        return -1;
    }
    return wait_for_child(current, pid, status, options);
}

static bool
child_is_running(pid_t pid)
{
    siginfo_t info;
    int result;
    do {
        result = peek_child(pid, WNOHANG, &info);
    } while (result < 0 && errno == EINTR);
    return result == 0 && info.si_pid == 0;
}

bool
CPython_SubprocessesHaveOpenPipes(CPython_Subprocesses *scope, const CPython_Files *files)
{
    for (CPython_Subprocess *child = scope->children; child != NULL; child = child->next) {
        bool has_pipes = CPython_HasOpenPipe(files, child->pipes[0]) ||
                         CPython_HasOpenPipe(files, child->pipes[1]) ||
                         CPython_HasOpenPipe(files, child->pipes[2]);
        if (has_pipes && child_is_running(child->pid)) {
            return true;
        }
    }
    return false;
}

int
CPython_JoinSubprocesses(CPython_Subprocesses *scope)
{
    int error = 0;
    while (scope->children != NULL) {
        pid_t pid = scope->children->pid;
        int status;
        pid_t result;
        do {
            result = wait_for_child(scope, pid, &status, 0);
        } while (result < 0 && errno == EINTR);
        if (result >= 0) {
            continue;
        }

        int failure = errno;
        if (error == 0) {
            error = failure;
        }
        CPython_StopSubprocesses(scope);
        if (failure != ECHILD) {
            // Fall back to the ordinary reap after terminating the group.
            // Stop is now idempotent, so it cannot signal a PID released here.
            do {
                result = waitpid(pid, &status, 0);
            } while (result < 0 && errno == EINTR);
            forget_child(scope, pid);
        }
    }
    return error;
}

void
CPython_FreeSubprocesses(CPython_Subprocesses *scope)
{
    CPython_StopSubprocesses(scope);
    (void)CPython_JoinSubprocesses(scope);
    pthread_mutex_destroy(&scope->lock);
    free(scope);
}

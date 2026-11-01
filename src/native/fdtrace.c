/*
 * GSI Loader Samsung 6.11 — fd-trace diagnostic shim (LD_PRELOAD).
 *
 * Purpose: PROVE which post-exec call opens the stray fd (64/68) that
 * the A16+ fd sanitizer rejects with 'Not allowlisted (N):
 * /data/zygote_stdio.log' in forkSystemServer. The 6.10 on-device run
 * proved the graphics-driver preload gate engages and changes nothing
 * (GL preload exonerated); the opener is still unknown and must no
 * longer be guessed. This shim records every open/openat/dup/dup2/
 * dup3/fcntl-dup in the process it is loaded into (the guest zygote
 * via LD_PRELOAD set by zygote_exec when the marker file exists).
 *
 * Safety contract (the shim runs inside ART; a bug here is itself a
 * new failure mode, so the rules are absolute):
 *  - NEVER hold a file descriptor open across calls. Every trace
 *    event is written with open-write-close (raw syscalls, never the
 *    interposed wrappers) to a DEDICATED trace file, never to the
 *    stdio capture file. No shim fd can therefore appear in the
 *    fork-time fd table — except for the microsecond the log write
 *    itself is in flight, a race documented here and accepted: if
 *    it ever fires, the abort names /data/gsi_fdtrace.log distinctly
 *    and cannot be confused with the stdio-log wall.
 *  - NEVER recurse: a thread-local guard makes every wrapper call
 *    the real function directly while resolving or logging, and all
 *    logging uses raw syscall() numbers, bypassing libc wrappers.
 *  - NEVER fail the host process: if the trace file cannot be
 *    opened, events are silently dropped; if the real function
 *    cannot be resolved, the raw syscall fallback runs instead.
 *  - NEVER alter semantics: every wrapper returns exactly what the
 *    real call returned, with errno preserved.
 *
 * The trace file path defaults to /data/gsi_fdtrace.log (guest /data
 * = the staged slot data dir, so it survives the session into the
 * diagnostics bundle). GSI_FDTRACE_LOG_PATH overrides it at compile
 * time (host harness); GSI_FDTRACE_LOG overrides it at runtime.
 * The shim is inert unless loaded: zygote_exec sets LD_PRELOAD only
 * when the marker file /data/gsi_fdtrace_on exists (toggled from the
 * app's Experimental menu). Default: OFF.
 *
 * Build (device): aarch64-linux-android35-clang -shared -fPIC -O2
 *   -o fdtrace.so fdtrace.c -ldl
 * Build (host harness): gcc -shared -fPIC -O2 -o libfdtrace_host.so
 *   fdtrace.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>

#ifndef GSI_FDTRACE_LOG_PATH
#define GSI_FDTRACE_LOG_PATH "/data/gsi_fdtrace.log"
#endif

/* The mode argument exists iff O_CREAT is set, or the __O_TMPFILE
 * bit ALONE is set (020000000). Testing the public O_TMPFILE macro
 * (020200000, which includes O_DIRECTORY) would falsely consume a
 * vararg on plain O_DIRECTORY opens. */
#define FDTRACE_NEEDS_MODE(f) (((f) & O_CREAT) || (((f) & 020000000) == 020000000))

/* ------------------------------------------------------------------ */
/* Real-function resolution with recursion guard.                      */
/* ------------------------------------------------------------------ */

static __thread int fdtrace_busy = 0;

typedef int (*open_fn_t)(const char *pathname, int flags, ...);
typedef int (*openat_fn_t)(int dirfd, const char *pathname, int flags, ...);
typedef int (*dup_fn_t)(int oldfd);
typedef int (*dup2_fn_t)(int oldfd, int newfd);
typedef int (*dup3_fn_t)(int oldfd, int newfd, int flags);
typedef int (*fcntl_fn_t)(int fd, int cmd, ...);

static open_fn_t real_open = NULL;
static openat_fn_t real_openat = NULL;
static dup_fn_t real_dup = NULL;
static dup2_fn_t real_dup2 = NULL;
static dup3_fn_t real_dup3 = NULL;
static fcntl_fn_t real_fcntl = NULL;

static void resolve_all(void) {
    if (real_open && real_openat && real_dup && real_dup2 && real_dup3 && real_fcntl) {
        return;
    }
    fdtrace_busy = 1;
    if (!real_open) real_open = (open_fn_t)dlsym(RTLD_NEXT, "open");
    if (!real_openat) real_openat = (openat_fn_t)dlsym(RTLD_NEXT, "openat");
    if (!real_dup) real_dup = (dup_fn_t)dlsym(RTLD_NEXT, "dup");
    if (!real_dup2) real_dup2 = (dup2_fn_t)dlsym(RTLD_NEXT, "dup2");
    if (!real_dup3) real_dup3 = (dup3_fn_t)dlsym(RTLD_NEXT, "dup3");
    if (!real_fcntl) real_fcntl = (fcntl_fn_t)dlsym(RTLD_NEXT, "fcntl");
    fdtrace_busy = 0;
}

/* Raw-syscall fallbacks (used only if dlsym fails). SYS_* comes from
 * <sys/syscall.h> on both arm64 and x86_64. */
static int fallback_open(const char *path, int flags, mode_t mode) {
#ifdef SYS_openat
    return (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
#else
    return (int)syscall(SYS_open, path, flags, mode);
#endif
}

static int fallback_openat(int dirfd, const char *path, int flags, mode_t mode) {
    return (int)syscall(SYS_openat, dirfd, path, flags, mode);
}

static int fallback_dup(int oldfd) {
    return (int)syscall(SYS_dup, oldfd);
}

static int fallback_dup2(int oldfd, int newfd) {
#ifdef SYS_dup3
    /* arm64 has no dup2 syscall; dup3 with flags 0 is identical. */
    return (int)syscall(SYS_dup3, oldfd, newfd, 0);
#elif defined(SYS_dup2)
    return (int)syscall(SYS_dup2, oldfd, newfd);
#else
    return (int)syscall(SYS_fcntl, oldfd, F_DUPFD, newfd);
#endif
}

static int fallback_dup3(int oldfd, int newfd, int flags) {
#ifdef SYS_dup3
    return (int)syscall(SYS_dup3, oldfd, newfd, flags);
#else
    (void)flags;
    return (int)syscall(SYS_dup2, oldfd, newfd);
#endif
}

static int fallback_fcntl(int fd, int cmd, long arg) {
    return (int)syscall(SYS_fcntl, fd, cmd, arg);
}

/* ------------------------------------------------------------------ */
/* Trace sink: one open-write-close per event, raw syscalls only.      */
/* ------------------------------------------------------------------ */

static const char *trace_path(void) {
    static const char *cached = NULL;
    static int cached_set = 0;
    if (!cached_set) {
        cached_set = 1;
        const char *env = getenv("GSI_FDTRACE_LOG");
        cached = (env && *env) ? env : GSI_FDTRACE_LOG_PATH;
    }
    return cached;
}

static void trace_write(const char *line, size_t len) {
    int fd = (int)syscall(SYS_openat, AT_FDCWD, trace_path(),
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) {
        return;
    }
    size_t off = 0;
    while (off < len) {
        ssize_t w = syscall(SYS_write, fd, line + off, len - off);
        if (w < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        off += (size_t)w;
    }
    syscall(SYS_close, fd);
}

/* Best-effort readlink of /proc/self/fd/N (no fd consumed: readlink
 * is not an interposed call). Empty string on any failure. */
static void fd_target(int fd, char *out, size_t out_size) {
    char linkpath[48];
    if (fd < 0 || out_size == 0) {
        if (out_size > 0) {
            out[0] = '\0';
        }
        return;
    }
    snprintf(linkpath, sizeof(linkpath), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(linkpath, out, out_size - 1);
    if (n < 0) {
        out[0] = '\0';
    } else {
        out[n] = '\0';
    }
}

static void trace_event(const char *op, const char *detail, int result_fd) {
    char line[1024];
    char target[512];
    fd_target(result_fd, target, sizeof(target));
    int n = snprintf(line, sizeof(line), "FDTRACE pid=%d op=%s %s -> fd=%d target=%s\n",
                     (int)getpid(), op, detail, result_fd, target);
    if (n <= 0) {
        return;
    }
    if ((size_t)n >= sizeof(line)) {
        n = (int)sizeof(line) - 1;
        line[n] = '\0';
    }
    trace_write(line, (size_t)n);
}

static void trace_event_nofd(const char *op, const char *detail, int result) {
    char line[1024];
    int n = snprintf(line, sizeof(line), "FDTRACE pid=%d op=%s %s -> result=%d errno=%d\n",
                     (int)getpid(), op, detail, result, errno);
    if (n <= 0) {
        return;
    }
    if ((size_t)n >= sizeof(line)) {
        n = (int)sizeof(line) - 1;
        line[n] = '\0';
    }
    trace_write(line, (size_t)n);
}

/* ------------------------------------------------------------------ */
/* Constructor: one INIT line per exec'd process, naming argv[0] so   */
/* the launcher phase (static binary: never loads the shim) and the   */
/* app_process phase are distinguishable even though execve keeps    */
/* the pid.                                                          */
/* ------------------------------------------------------------------ */

/* argv[0] for the INIT line. Bionic has no program_invocation_name,
 * so read the first token of /proc/self/cmdline with raw syscalls.
 * Never touches an interposed call. */
static void self_argv0(char *out, size_t out_size) {
    if (out_size == 0) {
        return;
    }
    out[0] = '\0';
    int fd = (int)syscall(SYS_openat, AT_FDCWD, "/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return;
    }
    size_t n = 0;
    while (n + 1 < out_size) {
        char c;
        ssize_t r = syscall(SYS_read, fd, &c, 1);
        if (r <= 0 || c == '\0') {
            break;
        }
        out[n++] = c;
    }
    out[n] = '\0';
    syscall(SYS_close, fd);
}

__attribute__((constructor))
static void fdtrace_init(void) {
    char argv0buf[256];
    self_argv0(argv0buf, sizeof(argv0buf));
    const char *argv0 = argv0buf[0] ? argv0buf : "?";
    char line[512];
    int n = snprintf(line, sizeof(line),
                     "FDTRACE_INIT pid=%d argv0=%s trace=%s\n",
                     (int)getpid(), argv0 ? argv0 : "?",
                     trace_path());
    if (n > 0) {
        if ((size_t)n >= sizeof(line)) {
            n = (int)sizeof(line) - 1;
        }
        trace_write(line, (size_t)n);
    }
}

/* ------------------------------------------------------------------ */
/* Interposed calls. Each: guard -> resolve -> real call -> trace.    */
/* errno is preserved across tracing.                                */
/* ------------------------------------------------------------------ */

int open(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (FDTRACE_NEEDS_MODE(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (fdtrace_busy) {
        if (real_open) {
            return real_open(pathname, flags, mode);
        }
        return fallback_open(pathname, flags, mode);
    }
    if (!real_open) {
        resolve_all();
    }
    int saved_errno;
    int fd;
    if (real_open) {
        fd = real_open(pathname, flags, mode);
    } else {
        fd = fallback_open(pathname, flags, mode);
    }
    saved_errno = errno;
    fdtrace_busy = 1;
    char detail[768];
    snprintf(detail, sizeof(detail), "path=%s flags=0x%x mode=0%o",
             pathname ? pathname : "?", flags, (unsigned)mode);
    if (fd >= 0) {
        trace_event("open", detail, fd);
    } else {
        trace_event_nofd("open", detail, fd);
    }
    fdtrace_busy = 0;
    errno = saved_errno;
    return fd;
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (FDTRACE_NEEDS_MODE(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (fdtrace_busy) {
        if (real_openat) {
            return real_openat(dirfd, pathname, flags, mode);
        }
        return fallback_openat(dirfd, pathname, flags, mode);
    }
    if (!real_openat) {
        resolve_all();
    }
    int fd;
    if (real_openat) {
        fd = real_openat(dirfd, pathname, flags, mode);
    } else {
        fd = fallback_openat(dirfd, pathname, flags, mode);
    }
    int saved_errno = errno;
    fdtrace_busy = 1;
    char detail[768];
    snprintf(detail, sizeof(detail), "dirfd=%d path=%s flags=0x%x mode=0%o",
             dirfd, pathname ? pathname : "?", flags, (unsigned)mode);
    if (fd >= 0) {
        trace_event("openat", detail, fd);
    } else {
        trace_event_nofd("openat", detail, fd);
    }
    fdtrace_busy = 0;
    errno = saved_errno;
    return fd;
}

int dup(int oldfd) {
    if (fdtrace_busy) {
        if (real_dup) {
            return real_dup(oldfd);
        }
        return fallback_dup(oldfd);
    }
    if (!real_dup) {
        resolve_all();
    }
    int fd = real_dup ? real_dup(oldfd) : fallback_dup(oldfd);
    int saved_errno = errno;
    fdtrace_busy = 1;
    char detail[128];
    snprintf(detail, sizeof(detail), "oldfd=%d", oldfd);
    if (fd >= 0) {
        trace_event("dup", detail, fd);
    } else {
        trace_event_nofd("dup", detail, fd);
    }
    fdtrace_busy = 0;
    errno = saved_errno;
    return fd;
}

int dup2(int oldfd, int newfd) {
    if (fdtrace_busy) {
        if (real_dup2) {
            return real_dup2(oldfd, newfd);
        }
        return fallback_dup2(oldfd, newfd);
    }
    if (!real_dup2) {
        resolve_all();
    }
    int rc = real_dup2 ? real_dup2(oldfd, newfd) : fallback_dup2(oldfd, newfd);
    int saved_errno = errno;
    fdtrace_busy = 1;
    char detail[128];
    snprintf(detail, sizeof(detail), "oldfd=%d newfd=%d", oldfd, newfd);
    if (rc >= 0) {
        trace_event("dup2", detail, rc);
    } else {
        trace_event_nofd("dup2", detail, rc);
    }
    fdtrace_busy = 0;
    errno = saved_errno;
    return rc;
}

int dup3(int oldfd, int newfd, int flags) {
    if (fdtrace_busy) {
        if (real_dup3) {
            return real_dup3(oldfd, newfd, flags);
        }
        return fallback_dup3(oldfd, newfd, flags);
    }
    if (!real_dup3) {
        resolve_all();
    }
    int rc = real_dup3 ? real_dup3(oldfd, newfd, flags) : fallback_dup3(oldfd, newfd, flags);
    int saved_errno = errno;
    fdtrace_busy = 1;
    char detail[128];
    snprintf(detail, sizeof(detail), "oldfd=%d newfd=%d flags=0x%x", oldfd, newfd, flags);
    if (rc >= 0) {
        trace_event("dup3", detail, rc);
    } else {
        trace_event_nofd("dup3", detail, rc);
    }
    fdtrace_busy = 0;
    errno = saved_errno;
    return rc;
}

int fcntl(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    void *argp = va_arg(ap, void *);
    va_end(ap);
    long arg = (long)argp;
    int is_dup_cmd = (cmd == F_DUPFD || cmd == F_DUPFD_CLOEXEC);
    if (!is_dup_cmd) {
        /* Pass through untouched (no trace: these calls cannot
         * create the stray fd, and tracing them would only add
         * noise — but the call itself must still go through the
         * real fcntl, including under the guard). */
        if (fdtrace_busy) {
            if (real_fcntl) {
                return real_fcntl(fd, cmd, argp);
            }
            return fallback_fcntl(fd, cmd, arg);
        }
        if (!real_fcntl) {
            resolve_all();
        }
        if (real_fcntl) {
            return real_fcntl(fd, cmd, argp);
        }
        return fallback_fcntl(fd, cmd, arg);
    }
    if (fdtrace_busy) {
        if (real_fcntl) {
            return real_fcntl(fd, cmd, (int)arg);
        }
        return fallback_fcntl(fd, cmd, arg);
    }
    if (!real_fcntl) {
        resolve_all();
    }
    int rc = real_fcntl ? real_fcntl(fd, cmd, (int)arg) : fallback_fcntl(fd, cmd, arg);
    int saved_errno = errno;
    fdtrace_busy = 1;
    char detail[160];
    snprintf(detail, sizeof(detail), "fd=%d cmd=%d arg=%ld", fd, cmd, arg);
    if (rc >= 0) {
        trace_event("fcntl-dup", detail, rc);
    } else {
        trace_event_nofd("fcntl-dup", detail, rc);
    }
    fdtrace_busy = 0;
    errno = saved_errno;
    return rc;
}

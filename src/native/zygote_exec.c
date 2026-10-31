/*
 * GSI Loader Samsung 6.0 (P2) — guest zygote launcher, rebuilt.
 *
 * Replaces the 6,400-byte black-box zygote_exec shipped since 5.7
 * (no source in tree, baked-in lists, no observable fallback or
 * logging) with a launcher whose BEHAVIOR is inspectable:
 *
 *  - Classpath hygiene: each of BOOTCLASSPATH, DEX2OATBOOTCLASSPATH,
 *    SYSTEMSERVERCLASSPATH, STANDALONE_SYSTEMSERVER_JARS is built by
 *    merging the environment value with the DEFAULT list below, then
 *    keeping only entries that (a) exist and are readable on disk,
 *    (b) do not name a Samsung/Knox jar (host classpath variables
 *    must never force foreign jars into the guest zygote), with
 *    duplicates removed. The result is logged to
 *    /data/zygote_exec.log. A guest that lacks a listed jar no
 *    longer breaks zygote at startup; the jar is dropped instead.
 *  - The DEFAULT lists are OUR 23.2-era lists, taken verbatim from
 *    the strings of the 5.9.18 binary they replace — not another
 *    project's lists. Newer guests keep every jar they actually
 *    ship; jars they lack are filtered, not fatal.
 *  - Zygote sockets: /dev/socket/zygote on fd 3 and
 *    /dev/socket/usap_pool_primary on fd 4 (root:system, 0660,
 *    CLOEXEC cleared), zygote_secondary linked to the primary,
 *    failures logged to /data/zygote_stderr.log (our established
 *    path) instead of dying silently.
 *  - Stdio is captured, not discarded. The 6.5 design forks a
 *    writer child and gives zygote a pipe for fds 0/1/2 (a pipe
 *    is not a regular file); the original rationale — that zygote
 *    aborts if stdio points at a regular file — was never proven
 *    on-device and is tested empirically by the 6.8 file mode
 *    (see the 6.8 note above). The child
 *    drains the pipe into /data/zygote_stdio.log (append) and
 *    exits on EOF. The writer drains even if the log cannot be
 *    opened, so zygote can never block on a full pipe. Pipe/fork
 *    failure falls back to /dev/null with a loud line in the
 *    launcher log. Stray fds >= 5 are closed.
 *  - 6.7: the 6.6 on-device run proved the pipe design is NOT the
 *    fork killer — zygote died in ForkCommon with "Unsupported
 *    st_mode for FD 68: FIFO", never on fds 0/1/2, across all 6
 *    attempts. The A16+ fd sanitizer therefore exempts stdio:
 *    pipes at 0/1/2 are fine, and the pipe design is KEPT on
 *    that in-device evidence (the regular-file-abort claim
 *    remains unproven, but there is no reason to switch). What
 *    6.7 adds is certainty about the exec-time fd table: the
 *    exec'd branch now closes every fd except 0/1/2 and the
 *    zygote socket fds out to 1024 (the 6.5 sweep stopped at
 *    256, leaving inherited high fds a way in), and dumps the
 *    full pre-exec fd table (fd -> target, type) into
 *    zygote_exec.log so the next on-device bundle proves which
 *    fds the exec'd branch actually inherits. NOTE from the
 *    in-tree trace: both pipe ends are already closed in the
 *    parent before the sweep, so a leftover launcher pipe fd
 *    cannot be FD 68 by that trace — if the dump shows a clean
 *    table and the abort persists, FD 68 is opened post-exec
 *    by ART/framework code, and the dump is what proves it.
 *  - 6.8: the 6.7 on-device dump EXONERATED the launcher — every
 *    attempt showed exactly 5 fds at exec (0/1/2 the capture pipe,
 *    3/4 the zygote sockets), no fd 68 — yet the fork still died
 *    with "Unsupported st_mode for FD 68: FIFO". FD 68 is therefore
 *    a FIFO opened POST-EXEC by ART/framework code, and no launcher
 *    close can remove it. AOSP's fd check (fd_utils.cpp) scans
 *    /proc/self/fd but SKIPS stdio (ParseFd drops fd <= 2), so the
 *    pipe at 0/1/2 was never scanned; the FIFO type check fails
 *    BEFORE any path allowlist is consulted, so no allowlist or
 *    property can save a FIFO, and the system-server fork's ignore
 *    list is built natively (USAP pipes only) with no outside
 *    input. What 6.8 adds is the decisive experiment: a stdio
 *    capture MODE SWITCH (env GSI_ZYGOTE_STDIO_MODE, selected from
 *    the shell side in master_inner.sh). File mode opens the stdio
 *    log directly as a regular file on 0/1/2 with no pipe and no
 *    writer child, and is the DEFAULT since 6.9 (no marker, no
 *    env, no shell step needed). Pipe mode is the 6.5 design,
 *    kept as the opt-in A/B alternative (env
 *    GSI_ZYGOTE_STDIO_MODE=pipe or the /data/gsi_stdio_pipe_mode
 *    marker), testing the long-unproven "zygote aborts if stdio is a
 *    regular file" claim empirically. If file mode still dies
 *    on FD 68, the FIFO is independent of stdio and the hunt
 *    moves to the post-exec openers (graphics-driver preload,
 *    app-process HAL preload — both vendor code). The mode is
 *    logged (ZYGOTE_STDIO_MODE) in both modes; the fd sweep and
 *    FD_TABLE dump run identically in both.
 *  - Four exec fallbacks in order: 64-bit with forced JIT zygote,
 *    64-bit without it, 32-bit with it, 32-bit without it. If all
 *    fail, the errno is logged and the process exits 1 so the
 *    master_inner.sh restart loop (P3) can log and bound the retry.
 *
 * Written for 6.0 from the Android zygote-launcher contract
 * (app_process arguments, socket fds, environment roots).
 * Static build: aarch64-linux-android35-clang -static -O2.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <ctype.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>

extern char **environ;

/* 6.5: zygote stdio capture target. Overridable at compile time
 * for the host harness only (GSI_ZYGOTE_STDIO_LOG_PATH); device
 * builds always use /data/zygote_stdio.log (guest /data = the
 * staged slot data dir, so the file survives the session). */
#ifndef GSI_ZYGOTE_STDIO_LOG_PATH
#define GSI_ZYGOTE_STDIO_LOG_PATH "/data/zygote_stdio.log"
#endif

/* OUR 23.2-era defaults, verbatim from the 5.9.18 binary's strings. */
static const char DEFAULT_BOOTCLASSPATH[] =
    "/apex/com.android.art/javalib/core-oj.jar:"
    "/apex/com.android.art/javalib/core-libart.jar:"
    "/apex/com.android.art/javalib/okhttp.jar:"
    "/apex/com.android.art/javalib/bouncycastle.jar:"
    "/apex/com.android.art/javalib/apache-xml.jar:"
    "/system/framework/framework.jar:"
    "/system/framework/framework-graphics.jar:"
    "/system/framework/framework-location.jar:"
    "/system/framework/ext.jar:"
    "/system/framework/telephony-common.jar:"
    "/system/framework/voip-common.jar:"
    "/system/framework/ims-common.jar:"
    "/system/framework/framework-ondeviceintelligence-platform.jar:"
    "/apex/com.android.i18n/javalib/core-icu4j.jar:"
    "/apex/com.android.adservices/javalib/framework-adservices.jar:"
    "/apex/com.android.adservices/javalib/framework-sdksandbox.jar:"
    "/apex/com.android.appsearch/javalib/framework-appsearch.jar:"
    "/apex/com.android.bt/javalib/framework-bluetooth.jar:"
    "/apex/com.android.configinfrastructure/javalib/framework-configinfrastructure.jar:"
    "/apex/com.android.conscrypt/javalib/conscrypt.jar:"
    "/apex/com.android.crashrecovery/javalib/framework-crashrecovery.jar:"
    "/apex/com.android.devicelock/javalib/framework-devicelock.jar:"
    "/apex/com.android.healthfitness/javalib/framework-healthfitness.jar:"
    "/apex/com.android.ipsec/javalib/android.net.ipsec.ike.jar:"
    "/apex/com.android.media/javalib/updatable-media.jar:"
    "/apex/com.android.mediaprovider/javalib/framework-mediaprovider.jar:"
    "/apex/com.android.mediaprovider/javalib/framework-pdf.jar:"
    "/apex/com.android.mediaprovider/javalib/framework-pdf-v.jar:"
    "/apex/com.android.mediaprovider/javalib/framework-photopicker.jar:"
    "/apex/com.android.nfcservices/javalib/framework-nfc.jar:"
    "/apex/com.android.ondevicepersonalization/javalib/framework-ondevicepersonalization.jar:"
    "/apex/com.android.os.statsd/javalib/framework-statsd.jar:"
    "/apex/com.android.permission/javalib/framework-permission.jar:"
    "/apex/com.android.permission/javalib/framework-permission-s.jar:"
    "/apex/com.android.profiling/javalib/framework-profiling.jar:"
    "/apex/com.android.scheduling/javalib/framework-scheduling.jar:"
    "/apex/com.android.sdkext/javalib/framework-sdkextensions.jar:"
    "/apex/com.android.telephonycore/javalib/framework-telephony.jar:"
    "/apex/com.android.tethering/javalib/framework-connectivity.jar:"
    "/apex/com.android.tethering/javalib/framework-connectivity-b.jar:"
    "/apex/com.android.tethering/javalib/framework-connectivity-t.jar:"
    "/apex/com.android.tethering/javalib/framework-tethering.jar:"
    "/apex/com.android.uwb/javalib/framework-ranging.jar:"
    "/apex/com.android.uwb/javalib/framework-uwb.jar:"
    "/apex/com.android.virt/javalib/framework-virtualization.jar:"
    "/apex/com.android.wifi/javalib/framework-wifi.jar";

static const char DEFAULT_DEX2OATBOOTCLASSPATH[] =
    "/apex/com.android.art/javalib/core-oj.jar:"
    "/apex/com.android.art/javalib/core-libart.jar:"
    "/apex/com.android.art/javalib/okhttp.jar:"
    "/apex/com.android.art/javalib/bouncycastle.jar:"
    "/apex/com.android.art/javalib/apache-xml.jar:"
    "/system/framework/framework.jar:"
    "/system/framework/framework-graphics.jar:"
    "/system/framework/framework-location.jar:"
    "/system/framework/ext.jar:"
    "/system/framework/telephony-common.jar:"
    "/system/framework/voip-common.jar:"
    "/system/framework/ims-common.jar:"
    "/system/framework/framework-ondeviceintelligence-platform.jar:"
    "/apex/com.android.i18n/javalib/core-icu4j.jar";

static const char DEFAULT_SYSTEMSERVERCLASSPATH[] =
    "/system/framework/com.android.location.provider.jar:"
    "/system/framework/services.jar:"
    "/system/framework/org.lineageos.platform.jar:"
    "/apex/com.android.adservices/javalib/service-adservices.jar:"
    "/apex/com.android.adservices/javalib/service-sdksandbox.jar:"
    "/apex/com.android.appsearch/javalib/service-appsearch.jar:"
    "/apex/com.android.art/javalib/service-art.jar:"
    "/apex/com.android.compos/javalib/service-compos.jar:"
    "/apex/com.android.configinfrastructure/javalib/service-configinfrastructure.jar:"
    "/apex/com.android.crashrecovery/javalib/service-crashrecovery.jar:"
    "/apex/com.android.healthfitness/javalib/service-healthfitness.jar:"
    "/apex/com.android.media/javalib/service-media-s.jar:"
    "/apex/com.android.ondevicepersonalization/javalib/service-ondevicepersonalization.jar:"
    "/apex/com.android.permission/javalib/service-permission.jar:"
    "/apex/com.android.rkpd/javalib/service-rkp.jar:"
    "/apex/com.android.virt/javalib/service-virtualization.jar";

static const char DEFAULT_STANDALONE_SYSTEMSERVER_JARS[] =
    "/apex/com.android.bt/javalib/service-bluetooth.jar:"
    "/apex/com.android.devicelock/javalib/service-devicelock.jar:"
    "/apex/com.android.os.statsd/javalib/service-statsd.jar:"
    "/apex/com.android.profiling/javalib/service-profiling.jar:"
    "/apex/com.android.scheduling/javalib/service-scheduling.jar:"
    "/apex/com.android.tethering/javalib/service-connectivity.jar:"
    "/apex/com.android.uwb/javalib/service-ranging.jar:"
    "/apex/com.android.uwb/javalib/service-uwb.jar:"
    "/apex/com.android.wifi/javalib/service-wifi.jar";

/* Case-insensitive substring test (for the Samsung/Knox strip). */
static int contains_ci(const char *haystack, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0) {
        return 1;
    }
    for (const char *p = haystack; *p; p++) {
        size_t i;
        for (i = 0; i < nlen; i++) {
            if (!p[i]) {
                break;
            }
            if (tolower((unsigned char)p[i]) != tolower((unsigned char)needle[i])) {
                break;
            }
        }
        if (i == nlen) {
            return 1;
        }
    }
    return 0;
}

/* Expand ${ANDROID_X_ROOT} / $ANDROID_X_ROOT placeholders. */
static void expand_path(const char *in, char *out, size_t out_size) {
    static const struct { const char *name; const char *value; } roots[] = {
        { "ANDROID_ART_ROOT", "/apex/com.android.art" },
        { "ANDROID_I18N_ROOT", "/apex/com.android.i18n" },
        { "ANDROID_TZDATA_ROOT", "/apex/com.android.tzdata" },
        { "ANDROID_ROOT", "/system" },
    };
    out[0] = '\0';
    const char *p = in;
    while (*p && strlen(out) + 1 < out_size) {
        int matched = 0;
        for (size_t r = 0; r < sizeof(roots) / sizeof(roots[0]); r++) {
            size_t nlen = strlen(roots[r].name);
            /* ${NAME} form */
            if (p[0] == '$' && p[1] == '{' && strncmp(p + 2, roots[r].name, nlen) == 0 && p[2 + nlen] == '}') {
                strncat(out, roots[r].value, out_size - strlen(out) - 1);
                p += 2 + nlen + 1;
                matched = 1;
                break;
            }
            /* $NAME form (must not be followed by an identifier char) */
            if (p[0] == '$' && strncmp(p + 1, roots[r].name, nlen) == 0 &&
                p[1 + nlen] != '_' && !isalnum((unsigned char)p[1 + nlen])) {
                strncat(out, roots[r].value, out_size - strlen(out) - 1);
                p += 1 + nlen;
                matched = 1;
                break;
            }
        }
        if (!matched) {
            size_t len = strlen(out);
            if (len + 1 < out_size) {
                out[len] = *p;
                out[len + 1] = '\0';
            }
            p++;
        }
    }
}

/*
 * Merge env value + default list, expand placeholders, drop entries
 * that are absent/unreadable or name Samsung/Knox jars, dedupe, and
 * install the result back into the environment. Logs the final
 * value to /data/zygote_exec.log. If nothing survives, the variable
 * is left untouched (callers fall back to their own behavior).
 */
static void sanitize_classpath(const char *env_var, const char *default_val) {
    const char *source = getenv(env_var);
    size_t alloc_sz = (source ? strlen(source) : 0) + (default_val ? strlen(default_val) : 0) + 8192;
    char *copy = malloc(alloc_sz);
    if (!copy) {
        return;
    }
    copy[0] = '\0';
    if (source && *source) {
        strcat(copy, source);
    }
    if (default_val && *default_val) {
        if (copy[0]) {
            strcat(copy, ":");
        }
        strcat(copy, default_val);
    }
    for (char *c = copy; *c; c++) {
        if (*c == '\r' || *c == '\n') {
            *c = '\0';
        }
    }

    char *buf = malloc(alloc_sz);
    if (!buf) {
        free(copy);
        return;
    }
    buf[0] = '\0';

    char expanded[1024];
    char *saveptr = NULL;
    char *token = strtok_r(copy, ":", &saveptr);
    while (token) {
        if (*token) {
            expand_path(token, expanded, sizeof(expanded));
            if (!contains_ci(expanded, "samsung") && !contains_ci(expanded, "knox") &&
                access(expanded, R_OK) == 0) {
                /* Dedupe: search ":entry:" inside ":buf:". */
                char *wrapped = malloc(strlen(buf) + 3);
                int already = 0;
                if (wrapped) {
                    sprintf(wrapped, ":%s:", buf);
                    char probe[1100];
                    snprintf(probe, sizeof(probe), ":%s:", expanded);
                    if (strstr(wrapped, probe) != NULL) {
                        already = 1;
                    }
                    free(wrapped);
                }
                if (!already) {
                    if (buf[0]) {
                        strcat(buf, ":");
                    }
                    strcat(buf, expanded);
                }
            }
        }
        token = strtok_r(NULL, ":", &saveptr);
    }

    if (buf[0]) {
        setenv(env_var, buf, 1);
        FILE *log = fopen("/data/zygote_exec.log", "a");
        if (log) {
            fprintf(log, "[gsi_zygote_exec] %s=%s\n", env_var, buf);
            fclose(log);
        }
    }
    free(buf);
    free(copy);
}

static void log_fatal(const char *msg) {
    int fd = open("/data/zygote_stderr.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        dprintf(fd, "FATAL: %s: %s\n", msg, strerror(errno));
        close(fd);
    }
}

/* 6.7: close every fd except 0/1/2 and the zygote socket fds
 * (3/4). The bound is 1024, not 256: the 6.5 sweep stopped at
 * 256, so an inherited fd numbered >= 256 could survive into
 * app_process. Closing is best-effort (EBADF on already-closed
 * fds is ignored) and never fatal. */
#define GSI_FD_SWEEP_MAX 1024
static void close_stray_fds(void) {
    for (int fd = 5; fd < GSI_FD_SWEEP_MAX; fd++) {
        close(fd);
    }
}

/*
 * 6.7: pre-exec fd-table dump. Reads /proc/self/fd and logs one
 * line per fd ("FD_TABLE: fd N -> target (type)") plus a closing
 * count line into /data/zygote_exec.log, so the next on-device
 * bundle proves exactly which fds the exec'd branch inherits.
 * The opendir fd itself is skipped (it appears in its own
 * listing); the log file is opened only after closedir() so the
 * dump's own fds never pollute the listing. Best-effort: any
 * failure logs nothing and changes nothing (the caller
 * re-sweeps afterwards, so a failed dump cannot leak fds into
 * app_process either).
 */
static void dump_fd_table(void) {
    DIR *d = opendir("/proc/self/fd");
    if (!d) {
        return;
    }
    int dfd = dirfd(d);
    int fds[GSI_FD_SWEEP_MAX];
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && n < GSI_FD_SWEEP_MAX) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') {
            continue;
        }
        int fd = atoi(e->d_name);
        if (fd == dfd) {
            continue;
        }
        fds[n++] = fd;
    }
    closedir(d);
    FILE *log = fopen("/data/zygote_exec.log", "a");
    if (!log) {
        return;
    }
    for (int i = 0; i < n; i++) {
        char linkpath[64];
        char target[512];
        struct stat st;
        const char *type = "stat-failed";
        if (fstat(fds[i], &st) == 0) {
            if (S_ISSOCK(st.st_mode)) {
                type = "socket";
            } else if (S_ISCHR(st.st_mode)) {
                type = "char";
            } else if (S_ISREG(st.st_mode)) {
                type = "regular";
            } else if (S_ISFIFO(st.st_mode)) {
                type = "FIFO";
            } else if (S_ISDIR(st.st_mode)) {
                type = "dir";
            } else if (S_ISBLK(st.st_mode)) {
                type = "block";
            } else {
                type = "other";
            }
        }
        snprintf(linkpath, sizeof(linkpath), "/proc/self/fd/%d", fds[i]);
        ssize_t tl = readlink(linkpath, target, sizeof(target) - 1);
        if (tl < 0) {
            target[0] = '\0';
        } else {
            target[tl] = '\0';
        }
        fprintf(log, "[gsi_zygote_exec] FD_TABLE: fd %d -> %s (%s)\n",
                fds[i], target, type);
    }
    fprintf(log, "[gsi_zygote_exec] FD_TABLE_END: %d fds (post-sweep, pre-exec)\n", n);
    fclose(log);
}

/*
 * 6.5 stdio writer child: drains read_fd (the read end of the
 * pipe zygote writes to) into GSI_ZYGOTE_STDIO_LOG_PATH, append
 * mode. Runs until EOF — i.e. until zygote AND every descendant
 * holding the write end are gone — then exits. If the log cannot
 * be opened, a loud marker goes to the launcher log and the pipe
 * is still drained (output dropped) so the writer never blocks
 * zygote. Only raw read/write: no stdio buffering, partial
 * writes retried, EINTR retried. _exit() only; never returns.
 */
static void stdio_writer_child(int read_fd) {
    for (int fd = 3; fd < 256; fd++) {
        if (fd != read_fd) {
            close(fd);
        }
    }
    int nullfd = open("/dev/null", O_RDWR);
    if (nullfd >= 0) {
        dup2(nullfd, 0);
        dup2(nullfd, 1);
        dup2(nullfd, 2);
        if (nullfd > 2) {
            close(nullfd);
        }
    }
    int logfd = open(GSI_ZYGOTE_STDIO_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (logfd < 0) {
        FILE *lg = fopen("/data/zygote_exec.log", "a");
        if (lg) {
            fprintf(lg, "[gsi_zygote_exec] ZYGOTE_STDIO_CAPTURE_FAILED: cannot open %s (%s) — zygote stdio discarded\n",
                    GSI_ZYGOTE_STDIO_LOG_PATH, strerror(errno));
            fclose(lg);
        }
    }
    char buf[8192];
    for (;;) {
        ssize_t n = read(read_fd, buf, sizeof(buf));
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (logfd >= 0) {
            ssize_t off = 0;
            int werr = 0;
            while (off < n) {
                ssize_t w = write(logfd, buf + off, (size_t)(n - off));
                if (w < 0) {
                    if (errno == EINTR) {
                        continue;
                    }
                    werr = 1;
                    break;
                }
                off += w;
            }
            if (werr) {
                /* Log dead (e.g. /data full): drop the rest but
                 * keep draining so zygote never blocks. */
                close(logfd);
                logfd = -1;
            }
        }
    }
    if (logfd >= 0) {
        close(logfd);
    }
    close(read_fd);
    _exit(0);
}

/* Create a Unix stream socket at path, bound to target_fd (3/4). */
static int setup_socket(const char *path, int target_fd) {
    unlink(path);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) {
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(s);
        return -1;
    }
    if (listen(s, 16) < 0) {
        close(s);
        return -1;
    }
    if (s != target_fd) {
        if (dup2(s, target_fd) < 0) {
            close(s);
            return -1;
        }
        close(s);
    }
    fchmod(target_fd, 0660);
    chmod(path, 0660);
    (void)fchown(target_fd, 0, 1000); /* root:system */
    (void)chown(path, 0, 1000);
    int flags = fcntl(target_fd, F_GETFD);
    if (flags >= 0) {
        fcntl(target_fd, F_SETFD, flags & ~FD_CLOEXEC);
    }
    return target_fd;
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    setpgid(0, 0);

    /* Android system environment roots (same set as the 5.9.18 binary). */
    if (!getenv("PATH")) setenv("PATH", "/system/bin:/system/xbin", 1);
    if (!getenv("ANDROID_ROOT")) setenv("ANDROID_ROOT", "/system", 1);
    if (!getenv("ANDROID_DATA")) setenv("ANDROID_DATA", "/data", 1);
    if (!getenv("ANDROID_STORAGE")) setenv("ANDROID_STORAGE", "/storage", 1);
    if (!getenv("ANDROID_ART_ROOT")) setenv("ANDROID_ART_ROOT", "/apex/com.android.art", 1);
    if (!getenv("ANDROID_I18N_ROOT")) setenv("ANDROID_I18N_ROOT", "/apex/com.android.i18n", 1);
    if (!getenv("ANDROID_TZDATA_ROOT")) setenv("ANDROID_TZDATA_ROOT", "/apex/com.android.tzdata", 1);
    if (!getenv("ANDROID_ASSETS")) setenv("ANDROID_ASSETS", "/system/app", 1);
    if (!getenv("EXTERNAL_STORAGE")) setenv("EXTERNAL_STORAGE", "/sdcard", 1);
    if (!getenv("ASEC_MOUNTPOINT")) setenv("ASEC_MOUNTPOINT", "/mnt/asec", 1);

    sanitize_classpath("BOOTCLASSPATH", DEFAULT_BOOTCLASSPATH);
    sanitize_classpath("DEX2OATBOOTCLASSPATH", DEFAULT_DEX2OATBOOTCLASSPATH);
    sanitize_classpath("SYSTEMSERVERCLASSPATH", DEFAULT_SYSTEMSERVERCLASSPATH);
    sanitize_classpath("STANDALONE_SYSTEMSERVER_JARS", DEFAULT_STANDALONE_SYSTEMSERVER_JARS);

    /* Dalvik-cache dirs (required by app_main's cache setup). */
    mkdir("/data/dalvik-cache", 0711);
    chmod("/data/dalvik-cache", 0711);
    (void)chown("/data/dalvik-cache", 0, 0);
    mkdir("/data/dalvik-cache/arm64", 0711);
    chmod("/data/dalvik-cache/arm64", 0711);
    (void)chown("/data/dalvik-cache/arm64", 0, 0);

    mkdir("/dev/socket", 0755);
    chmod("/dev/socket", 0755);
    if (setup_socket("/dev/socket/zygote", 3) < 0) {
        log_fatal("failed to setup /dev/socket/zygote");
        return 1;
    }
    setenv("ANDROID_SOCKET_zygote", "3", 1);
    unlink("/dev/socket/zygote_secondary");
    (void)symlink("/dev/socket/zygote", "/dev/socket/zygote_secondary");
    if (setup_socket("/dev/socket/usap_pool_primary", 4) < 0) {
        log_fatal("failed to setup /dev/socket/usap_pool_primary");
        return 1;
    }
    setenv("ANDROID_SOCKET_usap_pool_primary", "4", 1);

    /*
     * Stdio capture (6.5 pipe design; 6.8 mode switch; 6.9 default
     * flip). Mode is selected by the GSI_ZYGOTE_STDIO_MODE
     * environment variable, set from the shell side by
     * master_inner.sh (default FILE; pipe when the var is
     * "pipe"): pipe mode forks a writer child and gives zygote
     * opens /data/zygote_stdio.log directly as a regular file on
     * 0/1/2 with no pipe and no writer child. File mode is the
     * decisive experiment for the unproven "zygote aborts if
     * stdio is a regular file" claim — it must be selectable
     * without a rebuild so both modes can be run on-device.
     * Either mode's failure falls back to /dev/null with a loud
     * line in the launcher log. Then close stray fds >= 5 so
     * nothing leaks into app_process. (The pipe fds are >= 5:
     * fds 3/4 are the zygote sockets, set up above; the write
     * end is dup2'd onto 0/1/2 and its original closed before
     * the sweep. Both pipe ends are closed in this branch: the
     * read end just below, the write end right after the
     * dup2s. File mode opens no pipe at all.)
     * 6.7: sweep bound raised to 1024 and a pre-exec fd-table
     * dump added (see dump_fd_table) so the exec-time table is
     * proven on-device. The dump runs after the sweep and is
     * followed by a second sweep, so the dump's own fds cannot
     * leak into app_process. The sweep and dump run identically
     * in both modes.
     */
    int stdio_mode_file = 1; /* 6.9: file is the default; pipe is opt-in. */
    {
        const char *sm = getenv("GSI_ZYGOTE_STDIO_MODE");
        if (sm && strcmp(sm, "pipe") == 0) {
            stdio_mode_file = 0;
        }
    }
    {
        FILE *lg = fopen("/data/zygote_exec.log", "a");
        if (lg) {
            fprintf(lg, "[gsi_zygote_exec] ZYGOTE_STDIO_MODE: %s\n",
                    stdio_mode_file ? "file" : "pipe");
            fclose(lg);
        }
    }
    int cap_ok = 0;
    int cap_err_logged = 0;
    if (stdio_mode_file) {
        /* 6.8 file mode: stdio straight onto the log file. */
        int logfd = open(GSI_ZYGOTE_STDIO_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (logfd >= 0) {
            dup2(logfd, 0);
            dup2(logfd, 1);
            dup2(logfd, 2);
            if (logfd > 2) {
                close(logfd);
            }
            cap_ok = 1;
        } else {
            FILE *lg = fopen("/data/zygote_exec.log", "a");
            if (lg) {
                fprintf(lg, "[gsi_zygote_exec] ZYGOTE_STDIO_CAPTURE_FAILED: cannot open %s (%s) — stdio to /dev/null\n",
                        GSI_ZYGOTE_STDIO_LOG_PATH, strerror(errno));
                fclose(lg);
            }
            cap_err_logged = 1;
        }
    } else {
        int cap_pipe[2];
        if (pipe(cap_pipe) == 0) {
            pid_t wpid = fork();
            if (wpid == 0) {
                close(cap_pipe[1]);
                stdio_writer_child(cap_pipe[0]);
                _exit(0); /* unreachable */
            } else if (wpid > 0) {
                close(cap_pipe[0]);
                dup2(cap_pipe[1], 0);
                dup2(cap_pipe[1], 1);
                dup2(cap_pipe[1], 2);
                if (cap_pipe[1] > 2) {
                    close(cap_pipe[1]);
                }
                cap_ok = 1;
            } else {
                close(cap_pipe[0]);
                close(cap_pipe[1]);
            }
        }
    }
    if (!cap_ok) {
        if (!cap_err_logged) {
            FILE *lg = fopen("/data/zygote_exec.log", "a");
            if (lg) {
                fprintf(lg, "[gsi_zygote_exec] ZYGOTE_STDIO_CAPTURE_UNAVAILABLE: pipe/fork failed — stdio to /dev/null\n");
                fclose(lg);
            }
        }
        int null_fd = open("/dev/null", O_RDWR);
        if (null_fd >= 0) {
            dup2(null_fd, 0);
            dup2(null_fd, 1);
            dup2(null_fd, 2);
            if (null_fd > 2) {
                close(null_fd);
            }
        }
    }
    /* 6.7: close stray fds (0/1/2 + socket fds 3/4 survive), dump
     * the resulting table for on-device proof, then sweep again
     * so the dump's own fds cannot leak into app_process. */
    close_stray_fds();
    dump_fd_table();
    close_stray_fds();

#ifdef GSI_ZYGOTE_TEST_TARGET
    /* Host harness only (never defined in device builds): try a
     * fake app_process first so the pipe capture + exit/signal
     * reporting can be exercised on x86_64. */
    {
        char *targs[] = {
            "zygote64", "-Xzygote", "/system/bin",
            "--zygote", "--start-system-server", "--socket-name=zygote", NULL
        };
        execve(GSI_ZYGOTE_TEST_TARGET, targs, environ);
    }
#endif

    char *args64_jit[] = {
        "zygote64", "-Xzygote", "-Xforcejitzygote", "/system/bin",
        "--zygote", "--start-system-server", "--socket-name=zygote", NULL
    };
    execve("/system/bin/app_process64", args64_jit, environ);

    char *args64_nojit[] = {
        "zygote64", "-Xzygote", "/system/bin",
        "--zygote", "--start-system-server", "--socket-name=zygote", NULL
    };
    execve("/system/bin/app_process64", args64_nojit, environ);

    char *args32_jit[] = {
        "zygote", "-Xzygote", "-Xforcejitzygote", "/system/bin",
        "--zygote", "--start-system-server", "--socket-name=zygote", NULL
    };
    execve("/system/bin/app_process", args32_jit, environ);

    char *args32_nojit[] = {
        "zygote", "-Xzygote", "/system/bin",
        "--zygote", "--start-system-server", "--socket-name=zygote", NULL
    };
    execve("/system/bin/app_process", args32_nojit, environ);

    int err = errno;
    int fd = open("/data/zygote_stderr.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        dprintf(fd, "FATAL: execve app_process failed: %s (%d)\n", strerror(err), err);
        close(fd);
    }
    return 1;
}

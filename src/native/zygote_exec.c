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
 *  - 6.11: fd-trace diagnostic arming. The 6.10 on-device run proved
 *    the GL-preload gate engages and changes nothing (GL preload
 *    exonerated as the fd-64/68 opener), so the opener must be
 *    PROVEN. When the marker file /data/gsi_fdtrace_on exists (app
 *    Experimental toggle, default OFF) and /data/fdtrace.so is
 *    readable, this launcher sets LD_PRELOAD to the shim before
 *    exec: this binary is statically linked so the shim is ignored
 *    here and loads only in the dynamic app_process, with no
 *    re-exec. An exec-boundary line is appended to the trace file
 *    just before the execve fallbacks (the pid is shared across
 *    execve, so the boundary separates the phases). Marker absent
 *    or shim unreadable: loud log line, behavior exactly 6.10.
 *  - 6.12: SPLIT STDIO (Claude's experiment 1). File mode used to
 *    point fds 0/1/2 at the single /data/zygote_stdio.log. The
 *    6.9–6.11 on-device aborts name that path at a dup'd fd 64/68
 *    — and nothing in AOSP knows the path, so the fd is almost
 *    certainly a DUP of fd 0, 1 or 2 made post-exec. Splitting
 *    the targets (0 -> /dev/null RDONLY, 1 -> zygote_stdout.log,
 *    2 -> zygote_stderr_cap.log) makes the abort name WHICH stdio
 *    fd was duped; if fd 0 was the one, the wall vanishes
 *    outright (/dev/null is allowlisted). Per-fd fallback to the
 *    6.11 single-file behavior, loud line, never fatal. Pipe
 *    mode is UNCHANGED (all three fds -> the pipe) for A/B.
 *  - 6.13: STDOUT TO /dev/null (stepwise discriminator after the
 *    6.12 run). The 6.12 on-device abort named
 *    /data/zygote_stdout.log at fd 65 — fd 1 (stdout) is the
 *    duped handle, and the ascending scan stops at the first
 *    failure, so a duped fd 2 could still hide behind it. File
 *    mode now points fd 1 at /dev/null O_WRONLY as well (fd 0
 *    stays /dev/null RDONLY, fd 2 stays the stderr log). If the
 *    wall falls, fd 1 was the only culprit; if the next abort
 *    names the stderr log, fd 2 is duped too.
 *  - 6.14: ALL STDIO TO /dev/null (the discriminator's last
 *    step). The 6.13 on-device abort named
 *    /data/zygote_stderr_cap.log at fd 66 — fd 2 (stderr) is
 *    duped too, now that fd 1 is neutralized. File mode now
 *    points ALL THREE stdio fds at /dev/null (0 RDONLY, 1/2
 *    O_WRONLY) and opens NO capture file at all; the split-log
 *    path strings are gone from this binary. This SACRIFICES
 *    all zygote stdio capture on purpose: if the wall clears,
 *    the dup case is closed and the only job left is finding
 *    an allowlisted home for capture; if it still aborts
 *    identically, the dup theory is wrong. Pipe mode is
 *    UNCHANGED (capture pipe + writer child) for A/B. The fd
 *    sweep (to 1024) and FD_TABLE dump are unchanged and run
 *    identically in both modes; a failed /dev/null open falls
 *    back loudly, never silently, never to a capture file.
 *  - 6.15: APEX sweep (the fd wall is closed — see below).
 *    The 6.14 on-device run proved all-/dev/null works: zygote
 *    started, forked system_server, and system_server ran Java —
 *    then died ~2s in, identically on all 6 attempts, in
 *    PackageManagerService.scanApexPackages: "Unable to parse:
 *    /product/apex/com.google.android.gmssystem.prodvic.apex",
 *    IOException "Failed to load asset path" at
 *    ApkAssets.nativeLoad. One unreadable APEX file is fatal to
 *    PMS. The guest image is vanilla Lineage (no Google APEXes);
 *    the host's apex-info-list.xml is copied into the guest's
 *    /apex at prepare time, so the host's gmssystem entry leaks
 *    in with a modulePath the guest cannot open. Before exec,
 *    this launcher now reads /apex/apex-info-list.xml in the
 *    guest's own mount namespace, test-opens (open + first
 *    read) every modulePath, and bind-mounts a filtered copy
 *    over the list with the unreadable entries removed — so
 *    PMS never sees them. Readable entries are NEVER removed.
 *    Any sweep failure (no list, oversize list, scratch write
 *    or bind failure) logs loudly and continues the boot with
 *    the list untouched: the sweep can never block booting.
 *    Idempotent across supervisor-loop retries: a filtered
 *    list re-reads clean and the sweep no-ops.
 *  - 6.16: APEX bind (the APEX wall is a missing dir, not a
 *    poisoned list - see below). The 6.15 on-device runs proved
 *    the sweep works (gmssystem HIDDEN, kept=43 hidden=1) yet
 *    PMS still dies on the same modulePath: PMS reads its APEX
 *    set from host apexd over binder, not from
 *    apex-info-list.xml, so filtering the list can never reach
 *    it, and the guest never had /product/apex bound in, so
 *    the open fails ENOENT (ziparchive reports any failed open
 *    as a generic "I/O error"). Before the sweep, this launcher
 *    now binds every distinct modulePath parent dir the guest
 *    lacks (host dir found via the put_old mount or
 *    /proc/1/root) onto the guest path, make-rslave, with a
 *    tmpfs shadow mirroring the parent when the read-only
 *    image refuses the mountpoint. The sweep is UNTOUCHED and
 *    now keeps gmssystem once the bind makes it readable.
 *    Placement is native, not Java: no Java seam exists before
 *    the prepare script (the staged rootfs is not mounted yet
 *    when Java runs), so the bind runs post-pivot in this
 *    launcher, in the namespace the forked zygote inherits.
 *    Every bind failure logs loudly and the boot continues.
 *  - 6.17: DIAGNOSTICS ONLY — supervisor exit-status logging (see
 *    below). The 6.16 Lineage run proved the launcher's child is
 *    KILLED BY SIGNAL 9 (shell status 137) 6-10s in, 4 attempts:
 *    an outside killer (lmkd/OOM/supervisor), not a Java fatal
 *    (exit 10) or native abort (SIGABRT). This launcher used to
 *    execve directly and never wait, so no record of HOW each
 *    attempt died survived in its own log. main() now forks:
 *    the CHILD sets PR_SET_PDEATHSIG (SIGKILL) and execve's
 *    exactly as before (identical fd table, binds, environment,
 *    fallbacks); the PARENT waitpid()s, appends one ZYGOTE_EXIT
 *    line per attempt (raw status, exit code or signal,
 *    lifetime, timestamp) to zygote_exec.log, sleeps the
 *    existing backoff (2/4/8/16s), and repeats to the existing
 *    cap (5 attempts), then exits with the last status
 *    (128+signal when signaled, so the outer script sees the
 *    same 137 it sees today). The outer script remains the
 *    supervisor; this log is the authoritative per-attempt
 *    record. Binds, sweep, stdio, FD handling: UNTOUCHED.
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
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <signal.h>
#include <time.h>

extern char **environ;

/* 6.5: zygote stdio capture target. Overridable at compile time
 * for the host harness only (GSI_ZYGOTE_STDIO_LOG_PATH); device
 * builds always use /data/zygote_stdio.log (guest /data = the
 * staged slot data dir, so the file survives the session). */
#ifndef GSI_ZYGOTE_STDIO_LOG_PATH
#define GSI_ZYGOTE_STDIO_LOG_PATH "/data/zygote_stdio.log"
#endif

/* 6.14: the split-stdio log paths are GONE. File mode opens no
 * capture file at all — all three stdio fds go to /dev/null
 * (see setup_null_stdio_fd). The defines below existed for
 * 6.12/6.13 only and were deleted so the strings cannot reach
 * the device binary. Pipe mode still drains into
 * GSI_ZYGOTE_STDIO_LOG_PATH via the writer child, unchanged.
 * GSI_DEVNULL_PATH is overridable at compile time for the host
 * harness only; device builds always use /dev/null. */
#ifndef GSI_DEVNULL_PATH
#define GSI_DEVNULL_PATH "/dev/null"
#endif

/* 6.11: fd-trace diagnostic paths. Overridable at compile time for
 * the host harness only; device builds always use the /data paths
 * (guest /data = the staged slot data dir). The marker file is
 * created/removed by the app (Experimental toggle, default OFF);
 * the shim .so is staged next to this binary by the same Java sync
 * that stages zygote_exec itself. */
#ifndef GSI_FDTRACE_MARKER_PATH
#define GSI_FDTRACE_MARKER_PATH "/data/gsi_fdtrace_on"
#endif
#ifndef GSI_FDTRACE_SHIM_PATH
#define GSI_FDTRACE_SHIM_PATH "/data/fdtrace.so"
#endif
#ifndef GSI_FDTRACE_LOG_PATH
#define GSI_FDTRACE_LOG_PATH "/data/gsi_fdtrace.log"
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

/* 6.15: APEX sweep paths. Overridable at compile time for the
 * host harness only; device builds always use the /apex + /data
 * paths (guest /apex is the staged list, guest /data is the slot
 * data dir). GSI_ZYGOTE_LOG_PATH is used ONLY by the sweep; the
 * rest of this file keeps its literal /data/zygote_exec.log. */
#ifndef GSI_APEX_INFO_LIST_PATH
#define GSI_APEX_INFO_LIST_PATH "/apex/apex-info-list.xml"
#endif
#ifndef GSI_APEX_SWEEP_SCRATCH_PATH
#define GSI_APEX_SWEEP_SCRATCH_PATH "/data/.apex-info-list.sweep"
#endif
#ifndef GSI_ZYGOTE_LOG_PATH
#define GSI_ZYGOTE_LOG_PATH "/data/zygote_exec.log"
#endif

/* Cap on the list size the sweep will rewrite. The host list is
 * tens of entries; anything above the cap means something is
 * very wrong, and the sweep skips rather than risk truncating
 * the guest's view of active APEXes. */
#define GSI_APEX_LIST_MAX 262144
/* Lines longer than this are kept verbatim without parsing:
 * never drop an entry the parser cannot see whole. */
#define GSI_APEX_LINE_MAX 8192

/* Extract the value of attr="..." from one XML line. Returns 1
 * on success, 0 when the attribute is absent or unterminated. */
static int apex_attr_value(const char *line, const char *attr,
                           char *out, size_t out_sz) {
    char pat[64];
    snprintf(pat, sizeof(pat), "%s=\"", attr);
    const char *p = strstr(line, pat);
    if (!p) {
        return 0;
    }
    p += strlen(pat);
    const char *q = strchr(p, '"');
    if (!q) {
        return 0;
    }
    size_t n = (size_t)(q - p);
    if (n >= out_sz) {
        n = out_sz - 1;
    }
    memcpy(out, p, n);
    out[n] = '\0';
    return 1;
}

/* Probe one modulePath the way PMS will meet it: open + first
 * read, in this process's (guest) mount namespace. Returns 1
 * when at least one byte reads. On failure fills errbuf with a
 * short reason (errno string, or "empty file" for a 0-byte
 * read) so the on-device bundle discriminates ENOENT vs EIO vs
 * anything else. O_NONBLOCK: a FIFO at the path must never
 * wedge the launcher. */
static int apex_entry_readable(const char *path, char *errbuf, size_t errbuf_sz) {
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        snprintf(errbuf, errbuf_sz, "%s", strerror(errno));
        return 0;
    }
    char buf[512];
    ssize_t n;
    do {
        n = read(fd, buf, sizeof(buf));
    } while (n < 0 && errno == EINTR);
    int saved_errno = errno;
    close(fd);
    if (n <= 0) {
        snprintf(errbuf, errbuf_sz, "%s",
                 n == 0 ? "empty file" : strerror(saved_errno));
        return 0;
    }
    return 1;
}

/*
 * 6.15 APEX sweep. Reads /apex/apex-info-list.xml (the host
 * list copied into the guest at prepare time), test-opens every
 * modulePath in the guest's own mount namespace, and — only
 * when at least one entry is unreadable — bind-mounts a
 * filtered copy over the list with the unreadable entries
 * removed, so PackageManagerService never sees them. Readable
 * entries are NEVER removed. Any failure (no list, unreadable
 * or oversize list, scratch write or bind failure) logs loudly
 * and leaves the list untouched: the sweep can never block
 * booting. Runs before the fd sweep/dump, so its own fds are
 * proven closed by the FD_TABLE dump that follows.
 */
static void apex_sweep(void) {
    FILE *log = fopen(GSI_ZYGOTE_LOG_PATH, "a");
    int fd = open(GSI_APEX_INFO_LIST_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: no list at %s (%s) — nothing to filter\n",
                    GSI_APEX_INFO_LIST_PATH, strerror(errno));
            fclose(log);
        }
        return;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > GSI_APEX_LIST_MAX) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: list at %s unreadable or out of range — sweep skipped, list unchanged\n",
                    GSI_APEX_INFO_LIST_PATH);
            fclose(log);
        }
        close(fd);
        return;
    }
    size_t len = (size_t)st.st_size;
    char *data = malloc(len + 1);
    if (!data) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: out of memory — sweep skipped, list unchanged\n");
            fclose(log);
        }
        close(fd);
        return;
    }
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, data + got, len - got);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (n == 0) {
            break;
        }
        got += (size_t)n;
    }
    close(fd);
    if (got != len) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: short read on %s — sweep skipped, list unchanged\n",
                    GSI_APEX_INFO_LIST_PATH);
            fclose(log);
        }
        free(data);
        return;
    }
    data[len] = '\0';

    char *out = malloc(len + 1);
    if (!out) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: out of memory — sweep skipped, list unchanged\n");
            fclose(log);
        }
        free(data);
        return;
    }
    size_t out_len = 0;
    int kept = 0, hidden = 0;
    char *cur = data;
    while (*cur) {
        char *nl = strchr(cur, '\n');
        size_t linelen = nl ? (size_t)(nl - cur) + 1 : strlen(cur);
        int drop = 0;
        if (linelen < GSI_APEX_LINE_MAX) {
            char line[GSI_APEX_LINE_MAX];
            memcpy(line, cur, linelen);
            line[linelen] = '\0';
            if (strstr(line, "<apex-info") != NULL) {
                char modpath[1024];
                if (apex_attr_value(line, "modulePath", modpath, sizeof(modpath))) {
                    char errbuf[128];
                    if (!apex_entry_readable(modpath, errbuf, sizeof(errbuf))) {
                        char modname[256];
                        if (!apex_attr_value(line, "moduleName", modname, sizeof(modname))) {
                            size_t mlen = strlen(modpath);
                            if (mlen >= sizeof(modname)) {
                                mlen = sizeof(modname) - 1;
                            }
                            memcpy(modname, modpath, mlen);
                            modname[mlen] = '\0';
                        }
                        if (log) {
                            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: %s HIDDEN reason=%s path=%s\n",
                                    modname, errbuf, modpath);
                        }
                        hidden++;
                        drop = 1;
                    } else {
                        kept++;
                    }
                }
            }
        }
        if (!drop) {
            memcpy(out + out_len, cur, linelen);
            out_len += linelen;
        }
        cur += linelen;
    }
    out[out_len] = '\0';

    if (hidden == 0) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: kept=%d hidden=0 — list unchanged\n", kept);
            fclose(log);
        }
        free(out);
        free(data);
        return;
    }

    /* Write the filtered list to a scratch file, then bind it
     * over the list path. Scratch lives next to the list when
     * that directory is writable (guest /apex is a fresh
     * tmpfs), else the slot data dir. The original file is
     * never modified: only the guest's view of the path
     * changes, and only inside this mount namespace. */
    char scratch[1024];
    const char *slash = strrchr(GSI_APEX_INFO_LIST_PATH, '/');
    if (slash && (size_t)(slash - GSI_APEX_INFO_LIST_PATH) < sizeof(scratch) - 32) {
        size_t dlen = (size_t)(slash - GSI_APEX_INFO_LIST_PATH);
        if (dlen == 0) {
            dlen = 1;
        }
        memcpy(scratch, GSI_APEX_INFO_LIST_PATH, dlen);
        strcpy(scratch + dlen, "/.apex-info-list.sweep");
    } else {
        snprintf(scratch, sizeof(scratch), "%s", GSI_APEX_SWEEP_SCRATCH_PATH);
    }
    int wrote = 0;
    const char *written_path = NULL;
    for (int attempt = 0; attempt < 2 && !wrote; attempt++) {
        const char *path = attempt == 0 ? scratch : GSI_APEX_SWEEP_SCRATCH_PATH;
        int wfd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (wfd < 0) {
            continue;
        }
        size_t off = 0;
        int werr = 0;
        while (off < out_len) {
            ssize_t w = write(wfd, out + off, out_len - off);
            if (w < 0) {
                if (errno == EINTR) {
                    continue;
                }
                werr = 1;
                break;
            }
            off += (size_t)w;
        }
        close(wfd);
        if (!werr) {
            /* NOTE: never snprintf(scratch, "%s", path) here —
             * on attempt 0 path IS scratch, and snprintf with
             * overlapping src/dst is UB that empties the buffer
             * (found by strace: mount("") -> EINVAL). */
            written_path = path;
            wrote = 1;
        }
    }
    if (!wrote) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: kept=%d hidden=%d — scratch write failed, list unchanged\n",
                    kept, hidden);
            fclose(log);
        }
        free(out);
        free(data);
        return;
    }
    if (mount(written_path, GSI_APEX_INFO_LIST_PATH, NULL, MS_BIND, NULL) != 0) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: kept=%d hidden=%d — bind over %s failed (%s), list unchanged\n",
                    kept, hidden, GSI_APEX_INFO_LIST_PATH, strerror(errno));
            fclose(log);
        }
        unlink(written_path);
        free(out);
        free(data);
        return;
    }
    if (log) {
        fprintf(log, "[gsi_zygote_exec] APEX_SWEEP: kept=%d hidden=%d — filtered list bound over %s (scratch %s)\n",
                kept, hidden, GSI_APEX_INFO_LIST_PATH, written_path);
        fclose(log);
    }
    free(out);
    free(data);
}

/* 6.16 APEX bind. Runs in main() BEFORE apex_sweep() (the
 * sweep's filtered view would hide the very entries the bind
 * must see) and in the same guest mount namespace the forked
 * zygote inherits. The 6.15 sweep filters the XML list, but PMS
 * reads its APEX set from host apexd over binder, so the
 * filtered list never reaches PMS; PMS then opens each
 * reported modulePath in the guest namespace, where host-only
 * apex dirs (notably /product/apex) were never bound in and
 * the open fails ENOENT (reported by ziparchive as a generic
 * "I/O error"). This step makes those paths EXIST: for every
 * distinct modulePath parent dir in the host list that the
 * guest does not already have covered, it bind-mounts the host
 * dir onto the guest path. The host dir is found through the
 * previous-root mount (still mounted at its put_old path) or
 * /proc/1/root. The guest image is loop-mounted read-only, so
 * a missing mountpoint cannot be mkdir'd: the parent dir is
 * then shadowed with a tmpfs that first mirrors the parent's
 * existing children (one level, one bind per child, symlinks
 * recreated), so nothing the guest already has is hidden.
 * Every failure logs loudly and the boot continues: the bind
 * can never block booting. The 6.15 sweep is left untouched;
 * this step only adds the APEX_SWEEP_DIR / APEX_DIRS diagnostic
 * lines and the APEX_BIND lines. */
#ifndef GSI_APEX_BIND_TEST_ROOT
#define GSI_APEX_BIND_TEST_ROOT ""
#endif
#define GSI_APEX_BIND_MAX_DIRS 16
#define GSI_APEX_BIND_PATH_MAX 1024

/* Prefix a guest-namespace path with the harness test root
 * when one is compiled in; on device the prefix is empty and
 * the path passes through unchanged. Host-source paths are
 * never prefixed. Returns 1 on success, 0 on truncation. */
static int apex_guest_path(const char *dir, char *out, size_t out_sz) {
    int n;
    if (GSI_APEX_BIND_TEST_ROOT[0] != '\0') {
        n = snprintf(out, out_sz, "%s%s", GSI_APEX_BIND_TEST_ROOT, dir);
    } else {
        n = snprintf(out, out_sz, "%s", dir);
    }
    return n >= 0 && (size_t)n < out_sz;
}

/* Parent dir of path (everything before the last '/'; "/"
 * when the path has no parent dir). No trailing slash except
 * for the root itself. */
static void apex_dirname(const char *path, char *out, size_t out_sz) {
    const char *slash = strrchr(path, '/');
    size_t n;
    if (!slash || slash == path) {
        snprintf(out, out_sz, "/");
        return;
    }
    n = (size_t)(slash - path);
    if (n >= out_sz) {
        n = out_sz - 1;
    }
    memcpy(out, path, n);
    out[n] = '\0';
}

/* Basename of path (after the last '/'; the whole path when it
 * has no slash). */
static const char *apex_basename(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/* Covered means the guest already has this apex dir usable: it
 * exists, is a directory, and holds at least one readable
 * entry. Guest-payload dirs (/system/apex) and host-bound dirs
 * (/system_ext/apex, /odm/apex) satisfy this; a missing, empty,
 * or only-unreadable dir does not. */
static int apex_dir_covered(const char *guest_dir) {
    struct stat st;
    DIR *d;
    struct dirent *e;
    int tried = 0;
    if (stat(guest_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        return 0;
    }
    d = opendir(guest_dir);
    if (!d) {
        return 0;
    }
    while ((e = readdir(d)) != NULL) {
        char child[GSI_APEX_BIND_PATH_MAX];
        char errbuf[128];
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        if (snprintf(child, sizeof(child), "%s/%s", guest_dir, e->d_name) >= (int)sizeof(child)) {
            continue;
        }
        if (apex_entry_readable(child, errbuf, sizeof(errbuf))) {
            closedir(d);
            return 1;
        }
        if (++tried >= 4) {
            break;
        }
    }
    closedir(d);
    return 0;
}

/* Unescape "\040" (space) in a mountinfo field, in place. */
static void apex_unescape040(char *s) {
    char *r = s, *w = s;
    while (*r) {
        if (r[0] == '\\' && r[1] == '0' && r[2] == '4' && r[3] == '0') {
            *w++ = ' ';
            r += 4;
        } else {
            *w++ = *r++;
        }
    }
    *w = '\0';
}

/* Find the host-side dir for guest_dir. Scans
 * /proc/self/mountinfo for a mountpoint M such that
 * M + guest_dir exists as a directory (the previous root after
 * pivot_root stays mounted at its put_old path); the LAST
 * match wins, since pivot artifacts mount late. Falls back to
 * /proc/1/root. Returns 1 with out set, else 0. Per-candidate
 * failures are not logged (dozens of mountpoints). */
static int apex_find_host_dir(const char *guest_dir, char *out, size_t out_sz) {
    FILE *mi = fopen("/proc/self/mountinfo", "r");
    char line[2048];
    int found = 0;
    if (mi) {
        while (fgets(line, sizeof(line), mi)) {
            char mp[GSI_APEX_BIND_PATH_MAX];
            char cand[GSI_APEX_BIND_PATH_MAX];
            struct stat st;
            if (sscanf(line, "%*s %*s %*s %*s %1023s", mp) != 1) {
                continue;
            }
            apex_unescape040(mp);
            if (strncmp(mp, "/proc", 5) == 0 || strncmp(mp, "/sys", 4) == 0 ||
                strncmp(mp, "/dev", 4) == 0) {
                continue;
            }
            if (snprintf(cand, sizeof(cand), "%s%s", mp, guest_dir) >= (int)sizeof(cand)) {
                continue;
            }
            if (stat(cand, &st) == 0 && S_ISDIR(st.st_mode)) {
                int n = snprintf(out, out_sz, "%s", cand);
                if (n >= 0 && (size_t)n < out_sz) {
                    found = 1;
                }
            }
        }
        fclose(mi);
    }
    if (found) {
        return 1;
    }
    {
        char cand[GSI_APEX_BIND_PATH_MAX];
        struct stat st;
        if (snprintf(cand, sizeof(cand), "/proc/1/root%s", guest_dir) < (int)sizeof(cand) &&
            stat(cand, &st) == 0 && S_ISDIR(st.st_mode)) {
            int n = snprintf(out, out_sz, "%s", cand);
            if (n >= 0 && (size_t)n < out_sz) {
                return 1;
            }
        }
    }
    return 0;
}

/* Mirror the direct children of src into dst (dst is an empty
 * tmpfs): directories and files are bind-mounted (one level;
 * subtrees replicate with MS_REC), symlinks are recreated.
 * Best-effort per child; returns children mirrored. */
static int apex_mirror_children(const char *src, const char *dst, FILE *log) {
    DIR *d = opendir(src);
    struct dirent *e;
    int n = 0;
    if (!d) {
        return 0;
    }
    while ((e = readdir(d)) != NULL) {
        char sp[GSI_APEX_BIND_PATH_MAX];
        char dp[GSI_APEX_BIND_PATH_MAX];
        struct stat st;
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        if (snprintf(sp, sizeof(sp), "%s/%s", src, e->d_name) >= (int)sizeof(sp) ||
            snprintf(dp, sizeof(dp), "%s/%s", dst, e->d_name) >= (int)sizeof(dp)) {
            continue;
        }
        if (lstat(sp, &st) != 0) {
            if (log) {
                int se = errno;
                fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_FAIL: %s (%s)\n", sp, strerror(se));
            }
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            if (mkdir(dp, 0755) != 0 && errno != EEXIST) {
                if (log) {
                    int se = errno;
                    fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_FAIL: mkdir %s (%s)\n", dp, strerror(se));
                }
                continue;
            }
            if (mount(sp, dp, NULL, MS_REC | MS_BIND, NULL) != 0) {
                if (log) {
                    int se = errno;
                    fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_FAIL: bind %s -> %s (%s)\n", sp, dp, strerror(se));
                }
                continue;
            }
            n++;
        } else if (S_ISLNK(st.st_mode)) {
            char tgt[GSI_APEX_BIND_PATH_MAX];
            ssize_t k = readlink(sp, tgt, sizeof(tgt) - 1);
            if (k < 0) {
                if (log) {
                    int se = errno;
                    fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_FAIL: readlink %s (%s)\n", sp, strerror(se));
                }
                continue;
            }
            tgt[k] = '\0';
            unlink(dp);
            if (symlink(tgt, dp) != 0) {
                if (log) {
                    int se = errno;
                    fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_FAIL: symlink %s (%s)\n", dp, strerror(se));
                }
                continue;
            }
            n++;
        } else if (S_ISREG(st.st_mode)) {
            int fd = open(dp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
            if (fd < 0) {
                if (log) {
                    int se = errno;
                    fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_FAIL: create %s (%s)\n", dp, strerror(se));
                }
                continue;
            }
            close(fd);
            if (mount(sp, dp, NULL, MS_REC | MS_BIND, NULL) != 0) {
                if (log) {
                    int se = errno;
                    fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_FAIL: bind %s -> %s (%s)\n", sp, dp, strerror(se));
                }
                continue;
            }
            n++;
        } else if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND_MIRROR_SKIP: %s (not dir/link/file)\n", sp);
        }
    }
    closedir(d);
    return n;
}

/* Mount a fresh tmpfs at a scratch dir for a shadow. Tries the
 * harness test-root scratch first when compiled in, then the
 * writable host tmpfs dirs. Returns 1 with scratch set. */
static int apex_mount_shadow_tmpfs(char *scratch, size_t scratch_sz) {
    static const char *lits[3] = { "/dev/.apex_shadow_tmp", "/mnt/.apex_shadow_tmp", "/data/.apex_shadow_tmp" };
    char cand[GSI_APEX_BIND_PATH_MAX];
    int i;
    if (GSI_APEX_BIND_TEST_ROOT[0] != '\0') {
        if (snprintf(cand, sizeof(cand), "%s/.apex_shadow_scratch",
                     GSI_APEX_BIND_TEST_ROOT) < (int)sizeof(cand)) {
            mkdir(cand, 0755);
            if (mount("tmpfs", cand, "tmpfs", 0, "size=16M") == 0) {
                snprintf(scratch, scratch_sz, "%s", cand);
                return 1;
            }
        }
    }
    for (i = 0; i < 3; i++) {
        mkdir(lits[i], 0755);
        if (mount("tmpfs", lits[i], "tmpfs", 0, "size=16M") == 0) {
            snprintf(scratch, scratch_sz, "%s", lits[i]);
            return 1;
        }
    }
    return 0;
}

/* Ensure guest_dir exists as a directory. Plain mkdir first;
 * when the read-only image refuses it, shadow the parent dir
 * with a tmpfs that mirrors the parent's existing children,
 * then the mountpoint exists inside the writable shadow.
 * Returns 1 when guest_dir is a directory afterwards. */
static int apex_ensure_mountpoint(const char *guest_dir, FILE *log) {
    struct stat st;
    char parent[GSI_APEX_BIND_PATH_MAX];
    char scratch[GSI_APEX_BIND_PATH_MAX];
    char mntpoint[GSI_APEX_BIND_PATH_MAX];
    int mirrored;
    if (stat(guest_dir, &st) == 0) {
        return S_ISDIR(st.st_mode) ? 1 : 0;
    }
    if (mkdir(guest_dir, 0755) == 0) {
        return 1;
    }
    if (errno == EEXIST) {
        if (stat(guest_dir, &st) == 0 && S_ISDIR(st.st_mode)) {
            return 1;
        }
        return 0;
    }
    apex_dirname(guest_dir, parent, sizeof(parent));
    if (strcmp(parent, "/") == 0) {
        return 0;
    }
    if (stat(parent, &st) != 0 || !S_ISDIR(st.st_mode)) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=no-parent target=%s\n", guest_dir, guest_dir);
        }
        return 0;
    }
    if (!apex_mount_shadow_tmpfs(scratch, sizeof(scratch))) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=no-scratch target=%s\n", guest_dir, guest_dir);
        }
        return 0;
    }
    mirrored = apex_mirror_children(parent, scratch, log);
    if (log) {
        fprintf(log, "[gsi_zygote_exec] APEX_BIND_SHADOW: %s mirrored %d children into %s\n", parent, mirrored, scratch);
    }
    if (snprintf(mntpoint, sizeof(mntpoint), "%s/%s", scratch, apex_basename(guest_dir)) >= (int)sizeof(mntpoint)) {
        return 0;
    }
    if (mkdir(mntpoint, 0755) != 0 && errno != EEXIST) {
        if (log) {
            int se = errno;
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=shadow-mkdir-%s target=%s\n", guest_dir, strerror(se), guest_dir);
        }
        return 0;
    }
    /* MS_REC: the mirrored child binds must replicate into the
     * shadow; a plain bind would leave them as empty dirs. */
    if (mount(scratch, parent, NULL, MS_REC | MS_BIND, NULL) != 0) {
        if (log) {
            int se = errno;
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=shadow-bind-%s target=%s\n", guest_dir, strerror(se), guest_dir);
        }
        return 0;
    }
    if (mount(NULL, parent, NULL, MS_REC | MS_SLAVE, NULL) != 0 && log) {
        int se = errno;
        fprintf(log, "[gsi_zygote_exec] APEX_BIND_RSLAVE_WARN: %s (%s) — shadow stands\n", parent, strerror(se));
    }
    if (stat(guest_dir, &st) == 0 && S_ISDIR(st.st_mode)) {
        return 1;
    }
    return 0;
}

/* Bind one host apex dir into the guest. dir is the guest-side
 * path as named in the list (unprefixed, used for logs and for
 * host-source discovery); filesystem operations use the
 * test-root-prefixed path when compiled in. */
static void apex_bind_one(const char *dir, FILE *log, int *bound, int *skipped, int *failed) {
    char gdir[GSI_APEX_BIND_PATH_MAX];
    char src[GSI_APEX_BIND_PATH_MAX];
    if (!apex_guest_path(dir, gdir, sizeof(gdir))) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=path-too-long target=%s\n", dir, dir);
        }
        (*failed)++;
        return;
    }
    if (apex_dir_covered(gdir)) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s SKIPPED reason=covered target=%s\n", dir, dir);
        }
        (*skipped)++;
        return;
    }
    if (!apex_find_host_dir(dir, src, sizeof(src))) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=no-host-source target=%s\n", dir, dir);
        }
        (*failed)++;
        return;
    }
    if (log) {
        fprintf(log, "[gsi_zygote_exec] APEX_BIND_SRC: %s <- %s\n", dir, src);
    }
    if (!apex_ensure_mountpoint(gdir, log)) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=no-mountpoint src=%s target=%s\n", dir, src, dir);
        }
        (*failed)++;
        return;
    }
    if (mount(src, gdir, NULL, MS_BIND, NULL) != 0) {
        if (log) {
            int se = errno;
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s FAIL reason=bind-%s src=%s target=%s\n", dir, strerror(se), src, dir);
        }
        (*failed)++;
        return;
    }
    if (mount(NULL, gdir, NULL, MS_REC | MS_SLAVE, NULL) != 0 && log) {
        int se = errno;
        fprintf(log, "[gsi_zygote_exec] APEX_BIND_RSLAVE_WARN: %s (%s) — bind stands\n", dir, strerror(se));
    }
    {
        DIR *d = opendir(gdir);
        int n = 0;
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)) != NULL) {
                if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0) {
                    n++;
                }
            }
            closedir(d);
        }
        if (n > 0) {
            if (log) {
                fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s BOUND src=%s target=%s entries=%d\n", dir, src, dir, n);
            }
        } else {
            if (log) {
                fprintf(log, "[gsi_zygote_exec] APEX_BIND: %s BOUND-UNVERIFIED src=%s target=%s entries=0\n", dir, src, dir);
            }
        }
        (*bound)++;
    }
}

/* 6.16 driver: read the host list, log the APEX_SWEEP_DIR /
 * APEX_DIRS diagnostics, and bind every distinct modulePath
 * parent dir the guest lacks. Runs before apex_sweep(). Any
 * failure logs loudly and leaves the boot running. */
static void apex_bind(void) {
    FILE *log = fopen(GSI_ZYGOTE_LOG_PATH, "a");
    int fd = open(GSI_APEX_INFO_LIST_PATH, O_RDONLY | O_CLOEXEC);
    struct stat st;
    char *data = NULL;
    size_t len = 0;
    char dirs[GSI_APEX_BIND_MAX_DIRS][GSI_APEX_BIND_PATH_MAX];
    int ndirs = 0, truncated = 0;
    int bound = 0, skipped = 0, failed = 0;
    char *cur;
    int i;
    if (fd < 0) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: no list at %s (%s) — bind skipped, boot continues\n",
                    GSI_APEX_INFO_LIST_PATH, strerror(errno));
            fclose(log);
        }
        return;
    }
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > GSI_APEX_LIST_MAX) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: list at %s unreadable or out of range — bind skipped, boot continues\n",
                    GSI_APEX_INFO_LIST_PATH);
            fclose(log);
        }
        close(fd);
        return;
    }
    len = (size_t)st.st_size;
    data = malloc(len + 1);
    if (!data) {
        if (log) {
            fprintf(log, "[gsi_zygote_exec] APEX_BIND: out of memory — bind skipped, boot continues\n");
            fclose(log);
        }
        close(fd);
        return;
    }
    {
        size_t got = 0;
        while (got < len) {
            ssize_t n = read(fd, data + got, len - got);
            if (n < 0) {
                if (errno == EINTR) {
                    continue;
                }
                break;
            }
            if (n == 0) {
                break;
            }
            got += (size_t)n;
        }
        close(fd);
        if (got != len) {
            if (log) {
                fprintf(log, "[gsi_zygote_exec] APEX_BIND: short read on %s — bind skipped, boot continues\n",
                        GSI_APEX_INFO_LIST_PATH);
                fclose(log);
            }
            free(data);
            return;
        }
    }
    data[len] = '\0';
    cur = data;
    while (*cur) {
        char *nl = strchr(cur, '\n');
        size_t linelen = nl ? (size_t)(nl - cur) + 1 : strlen(cur);
        if (linelen < GSI_APEX_LINE_MAX) {
            char line[GSI_APEX_LINE_MAX];
            memcpy(line, cur, linelen);
            line[linelen] = '\0';
            if (strstr(line, "<apex-info") != NULL) {
                char modpath[1024];
                if (apex_attr_value(line, "modulePath", modpath, sizeof(modpath))) {
                    char errbuf[128];
                    char dname[GSI_APEX_BIND_PATH_MAX];
                    int seen = 0;
                    if (!apex_entry_readable(modpath, errbuf, sizeof(errbuf)) &&
                        strcmp(errbuf, "No such file or directory") == 0) {
                        apex_dirname(modpath, dname, sizeof(dname));
                        if (log) {
                            fprintf(log, "[gsi_zygote_exec] APEX_SWEEP_DIR: %s\n", dname);
                        }
                    }
                    apex_dirname(modpath, dname, sizeof(dname));
                    for (i = 0; i < ndirs; i++) {
                        if (strcmp(dirs[i], dname) == 0) {
                            seen = 1;
                            break;
                        }
                    }
                    if (!seen) {
                        if (ndirs < GSI_APEX_BIND_MAX_DIRS) {
                            snprintf(dirs[ndirs], sizeof(dirs[ndirs]), "%s", dname);
                            ndirs++;
                        } else {
                            truncated = 1;
                        }
                    }
                }
            }
        }
        cur += linelen;
    }
    if (log) {
        if (ndirs == 0) {
            fprintf(log, "[gsi_zygote_exec] APEX_DIRS: (none)\n");
        } else {
            char joined[2048];
            size_t used = 0;
            joined[0] = '\0';
            for (i = 0; i < ndirs; i++) {
                size_t need = strlen(dirs[i]) + (i > 0 ? 1 : 0) + 1;
                if (used + need > sizeof(joined)) {
                    break;
                }
                if (i > 0) {
                    joined[used++] = ' ';
                    joined[used] = '\0';
                }
                strcpy(joined + used, dirs[i]);
                used += strlen(dirs[i]);
            }
            fprintf(log, "[gsi_zygote_exec] APEX_DIRS: %s%s\n", joined, truncated ? " ..." : "");
        }
    }
    for (i = 0; i < ndirs; i++) {
        apex_bind_one(dirs[i], log, &bound, &skipped, &failed);
    }
    if (log) {
        fprintf(log, "[gsi_zygote_exec] APEX_BIND: done bound=%d skipped=%d failed=%d dirs=%d%s\n",
                bound, skipped, failed, ndirs, truncated ? " (dirs truncated)" : "");
        fclose(log);
    }
    free(data);
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
 * 6.14: set up ONE stdio fd at /dev/null. Opens GSI_DEVNULL_PATH
 * with `flags`, dup2s it onto target_fd, closes the original
 * (unless open returned target_fd itself). On open failure,
 * logs LOUDLY and returns -1 so the caller can retry that fd
 * with a fresh /dev/null open — NEVER silently, NEVER to a
 * capture file: in 6.14 file mode no capture file exists to
 * fall back to, by design. Returns 1 on success, -1 on
 * failure. Never fatal.
 */
static int setup_null_stdio_fd(int flags, int target_fd, const char *label) {
    int fd = open(GSI_DEVNULL_PATH, flags);
    if (fd >= 0) {
        if (fd != target_fd) {
            dup2(fd, target_fd);
            close(fd);
        }
        return 1;
    }
    int saved_errno = errno;
    FILE *lg = fopen("/data/zygote_exec.log", "a");
    if (lg) {
        fprintf(lg, "[gsi_zygote_exec] ZYGOTE_STDIO_NULL_FAILED: %s (/dev/null) open failed (%s) — fd %d left for the /dev/null retry below; no capture file is opened\n",
                label, strerror(saved_errno), target_fd);
        fclose(lg);
    }
    return -1;
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
    /* 6.11: fd-trace arming — FIRST, before any other work. This
     * binary is statically linked, so LD_PRELOAD is ignored for
     * this process itself and only takes effect in the dynamic
     * app_process it execs: no re-exec is needed, the environment
     * is inherited across execve. The shim is armed only when the
     * marker file exists AND the .so is present and readable;
     * anything else logs loudly and proceeds exactly as 6.10. */
    int fdtrace_active = 0;
    {
        if (access(GSI_FDTRACE_MARKER_PATH, F_OK) == 0) {
            if (access(GSI_FDTRACE_SHIM_PATH, R_OK) == 0) {
                const char *old = getenv("LD_PRELOAD");
                char buf[2048];
                if (old && *old) {
                    snprintf(buf, sizeof(buf), "%s:%s", GSI_FDTRACE_SHIM_PATH, old);
                } else {
                    snprintf(buf, sizeof(buf), "%s", GSI_FDTRACE_SHIM_PATH);
                }
                setenv("LD_PRELOAD", buf, 1);
                setenv("GSI_FDTRACE_ACTIVE", "1", 1);
                fdtrace_active = 1;
                FILE *lg = fopen("/data/zygote_exec.log", "a");
                if (lg) {
                    fprintf(lg, "[gsi_zygote_exec] FDTRACE_ARMED: marker present, LD_PRELOAD=%s\n", buf);
                    fclose(lg);
                }
            } else {
                FILE *lg = fopen("/data/zygote_exec.log", "a");
                if (lg) {
                    fprintf(lg, "[gsi_zygote_exec] FDTRACE_SHIM_MISSING: marker present but %s unreadable — proceeding WITHOUT the fd-trace shim\n",
                            GSI_FDTRACE_SHIM_PATH);
                    fclose(lg);
                }
            }
        }
    }
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

    /* 6.16: APEX bind — make every distinct modulePath parent
     * dir exist in the guest namespace (see apex_bind) BEFORE
     * the sweep reads the list: the sweep's filtered view
     * would hide the entries the bind must see, and after the
     * bind the sweep keeps entries that are now readable.
     * Fail-safe by construction (see apex_bind); runs before
     * the fd sweep/dump so the FD_TABLE proves its fds closed. */
    apex_bind();

    /* 6.15: APEX sweep — filter unreadable modulePaths out of
     * the guest's apex-info-list.xml before anything reads it.
     * Fail-safe by construction (see apex_sweep); runs before
     * the fd sweep/dump so the FD_TABLE proves its fds closed. */
    apex_sweep();

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
     * "pipe"): pipe mode forks a writer child and gives zygote a
     * pipe for fds 0/1/2; file mode (6.14) points all three fds
     * at /dev/null (0 RDONLY, 1/2 WRONLY) and opens NO capture
     * file at all, with no pipe and no writer child.
     * File mode is the
     * decisive experiment for the unproven "zygote aborts if
     * stdio is a regular file" claim — it must be selectable
     * without a rebuild so both modes can be run on-device.
     * A failed /dev/null open in file mode falls back loudly
     * (log line + retry), never silently, never to a capture
     * file. Then close stray fds >= 5 so
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
        /* 6.14 all stdio to /dev/null (last discriminator step:
         * the 6.13 run proved fd 2 is duped too). fd 0 ->
         * /dev/null (RDONLY), fd 1 -> /dev/null (WRONLY), fd 2
         * -> /dev/null (WRONLY). NO capture file is opened in
         * file mode — zygote stdio is discarded on purpose, so
         * a cleared wall proves the dup case and the only job
         * left is finding an allowlisted home for capture. A
         * failed /dev/null open on any fd is logged loudly by
         * setup_null_stdio_fd and retried below with a fresh
         * open; it NEVER falls back to a capture file. The
         * FD_TABLE dump below is the arbiter: it must show
         * 0/1/2 -> /dev/null. Pipe mode below is unchanged. */
        int r0 = setup_null_stdio_fd(O_RDONLY, 0, "stdin");
        int r1 = setup_null_stdio_fd(O_WRONLY, 1, "stdout");
        int r2 = setup_null_stdio_fd(O_WRONLY, 2, "stderr");
        {
            FILE *lg = fopen("/data/zygote_exec.log", "a");
            if (lg) {
                fprintf(lg, "[gsi_zygote_exec] ZYGOTE_STDIO_NULL: stdin=%s stdout=%s stderr=%s (6.14: all stdio to /dev/null, no capture file)\n",
                        r0 > 0 ? "null" : "FAILED",
                        r1 > 0 ? "null" : "FAILED",
                        r2 > 0 ? "null" : "FAILED");
                fclose(lg);
            }
        }
        if (r0 < 0 || r1 < 0 || r2 < 0) {
            int nfd = open(GSI_DEVNULL_PATH, O_RDWR);
            if (nfd >= 0) {
                if (r0 < 0) {
                    dup2(nfd, 0);
                }
                if (r1 < 0) {
                    dup2(nfd, 1);
                }
                if (r2 < 0) {
                    dup2(nfd, 2);
                }
                if (nfd > 2) {
                    close(nfd);
                }
            } else {
                FILE *lg = fopen("/data/zygote_exec.log", "a");
                if (lg) {
                    fprintf(lg, "[gsi_zygote_exec] ZYGOTE_STDIO_NULL_RETRY_FAILED: /dev/null retry open failed (%s) — failed stdio fds left as-is, loudly\n",
                            strerror(errno));
                    fclose(lg);
                }
            }
        }
        cap_ok = 1;
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

    /* 6.11: exec-boundary marker in the trace file. Everything the
     * shim logs after this line is app_process (the pid is shared
     * across execve, so the boundary — not the pid — separates the
     * phases). Written with open-write-close, like the shim
     * itself, so no fd survives into app_process. */
    if (fdtrace_active) {
        int tfd = open(GSI_FDTRACE_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (tfd >= 0) {
            const char *b = "=== FDTRACE exec boundary: app_process next ===\n";
            size_t bl = strlen(b);
            size_t off = 0;
            while (off < bl) {
                ssize_t w = write(tfd, b + off, bl - off);
                if (w < 0) {
                    if (errno == EINTR) {
                        continue;
                    }
                    break;
                }
                off += (size_t)w;
            }
            close(tfd);
        }
    }

    /* 6.17: supervisor loop (diagnostics only). The launcher used
     * to execve below and never wait, so HOW each attempt died
     * was visible only in the outer script's log (which
     * truncates). Now: fork per attempt; the child dies with
     * this process (PR_SET_PDEATHSIG, so the outer script's
     * kill-spree still ends the guest) and execve's exactly as
     * before; the parent records one ZYGOTE_EXIT line per
     * attempt and retries to the existing cap with the existing
     * backoff, then exits with the last status. All setup above
     * (binds, sweep, sockets, stdio, fd table) is inherited
     * unchanged by the child: the fd table the exec'd branch
     * sees is identical to 6.16. A failed log open degrades to
     * no line, never a boot failure. */
    int sup_max_attempts = 5;
    int sup_backoff0 = 2; /* seconds; sequence 2,4,8,16 */
#ifdef GSI_ZYGOTE_TEST_TARGET
    /* Harness only (never defined in device builds): bound the
     * loop via env so regression scenarios stay fast. Defaults
     * are the production values. */
    {
        const char *e = getenv("GSI_TEST_MAX_ATTEMPTS");
        if (e) { int v = atoi(e); if (v >= 1 && v <= 5) sup_max_attempts = v; }
        e = getenv("GSI_TEST_BACKOFF0");
        if (e) { int v = atoi(e); if (v >= 0 && v <= 16) sup_backoff0 = v; }
    }
#endif
    int last_status = 1;
    for (int attempt = 1; attempt <= sup_max_attempts; attempt++) {
        time_t t0 = time(NULL);
        pid_t zpid = fork();
        if (zpid == 0) {
            /* Child: die with the parent, then exec exactly as
             * 6.16 did. The getppid check closes the
             * fork/prctl race: reparented to init means the
             * parent is already gone. */
            (void)prctl(PR_SET_PDEATHSIG, SIGKILL);
            if (getppid() == 1) _exit(127);
#ifdef GSI_ZYGOTE_TEST_TARGET
            /* Host harness only (never defined in device builds):
             * try a fake app_process first so the pipe capture +
             * exit/signal reporting can be exercised on x86_64. */
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
            _exit(1);
        }
        if (zpid < 0) {
            FILE *lg = fopen("/data/zygote_exec.log", "a");
            if (lg) {
                fprintf(lg, "[gsi_zygote_exec] ZYGOTE_FORK_FAILED: attempt=%d (%s) — backing off, boot continues\n",
                        attempt, strerror(errno));
                fclose(lg);
            }
            if (attempt < sup_max_attempts) {
                unsigned backoff = (unsigned)sup_backoff0 << (attempt - 1);
                if (backoff > 0) sleep(backoff);
            }
            continue;
        }
        int status = 0;
        pid_t w;
        do {
            w = waitpid(zpid, &status, 0);
        } while (w < 0 && errno == EINTR);
        time_t t1 = time(NULL);
        long after = (long)(t1 - t0);
        if (after < 0) after = 0;
        if (w < 0) {
            FILE *lg = fopen("/data/zygote_exec.log", "a");
            if (lg) {
                fprintf(lg, "[gsi_zygote_exec] ZYGOTE_WAIT_FAILED: attempt=%d pid=%d (%s) — boot continues, child reaped by init\n",
                        attempt, (int)zpid, strerror(errno));
                fclose(lg);
            }
            last_status = 1;
            break;
        }
        /* Reap a stray already-exited child (pipe-mode writer) so
         * no zombie lingers; the zygote child above is already
         * reaped, so this can only collect an exited sibling. */
        {
            int dummy = 0;
            (void)waitpid(-1, &dummy, WNOHANG);
        }
        last_status = status;
        {
            FILE *lg = fopen("/data/zygote_exec.log", "a");
            if (lg) {
                if (WIFEXITED(status)) {
                    fprintf(lg, "[gsi_zygote_exec] ZYGOTE_EXIT: attempt=%d status=%d exit=%d after=%lds at=%lld\n",
                            attempt, status, WEXITSTATUS(status), after, (long long)t1);
                } else if (WIFSIGNALED(status)) {
                    fprintf(lg, "[gsi_zygote_exec] ZYGOTE_EXIT: attempt=%d status=%d signal=%d after=%lds at=%lld\n",
                            attempt, status, WTERMSIG(status), after, (long long)t1);
                } else {
                    fprintf(lg, "[gsi_zygote_exec] ZYGOTE_EXIT: attempt=%d status=%d after=%lds at=%lld\n",
                            attempt, status, after, (long long)t1);
                }
                fclose(lg);
            }
        }
        if (attempt < sup_max_attempts) {
            unsigned backoff = (unsigned)sup_backoff0 << (attempt - 1);
            if (backoff > 0) sleep(backoff);
        }
    }
    /* Exit with the last status, shell-style: the outer script
     * sees the same 137 for a SIGKILLed guest it sees today. */
    if (WIFEXITED(last_status)) return WEXITSTATUS(last_status);
    if (WIFSIGNALED(last_status)) return 128 + WTERMSIG(last_status);
    return 1;
}

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
 *  - 6.18: SUPERVISOR-OWNED DIAGNOSTICS (Claude's adjusted plan).
 *    The 6.17 run reframed the wall: attempts 1-2 die by SIGKILL,
 *    attempt 3 probably never died (no exit line; supervisor logs
 *    only after waitpid returns) and the continuous-logcat capture
 *    itself died ~2s into attempt 3. The supervisor therefore
 *    owns the capture now (fork before the first zygote fork,
 *    death + restart logged, throttled restarts, previous file
 *    preserved as .restart<N>), keeps a heartbeat file with
 *    system_server aliveness, enables a best-effort tracefs
 *    signal tracer (signal_deliver/signal_generate), takes a
 *    death snapshot (logcat -d + dmesg + trace tail, no shell,
 *    25 s timeout) after every waitpid, and snapshots
 *    system_server's thread stacks (wchan + stack, per-thread
 *    fail-soft) at 60 s for the stuck-boot case. The wait is a
 *    poll loop so diagnostics stay serviced while the zygote
 *    runs and during backoffs. All 6.17 levers intact; every
 *    new path is fail-soft and can never break the boot.
 *  - 6.19: NAME THE SENDER (Claude's 6.19 design). The 6.18
 *    tracer produced nothing usable: signal_deliver records
 *    receiver-side fields only and cannot name a sender, the
 *    code treated it as the required event while
 *    signal_generate (the sender-naming event) was best-effort
 *    and never verified, no filters were set, and the trace
 *    was read late without switching tracing off. 6.19 enables
 *    ONLY signal_generate with the 6.26 fatal-signal filter (+ best-effort
 *    sched_process_exit), verifies every write by read-back,
 *    re-asserts events/filter/tracing_on every heartbeat tick,
 *    drains trace_pipe through a separate reader child into a
 *    /data file with per-chunk syncs, writes tracing_on=0
 *    FIRST at death, and puts the entries-in-buffer header in
 *    every snapshot. The child sets oom_score_adj=-1000 before
 *    execve (lmkd/OOM test); snapshots record the oom_kill
 *    counter, memory pressure, cgroups, a vold-ownership probe,
 *    and a self-classification (VOLD_CE_FATAL vs SIGKILL vs
 *    other); pidfds + CLOCK_BOOTTIME log the order of death;
 *    GSI_SUP log markers anchor the windowed extract; kills
 *    are PID-targeted with caller+time logging. All fail-soft.
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
#include <stdarg.h>
#include <poll.h>
#include <sys/syscall.h>

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

/* 6.18: supervisor-owned diagnostics. GSI_DIAG_DIR is the slot
 * data dir as this launcher sees it (guest /data IS the slot
 * data dir — see the 6.15 note above). All 6.18 diagnostic
 * files live here so the Java bundle collects them with the
 * same slot-data-first rule as zygote_exec.log. Overridable at
 * compile time for the host harness only. */
#ifndef GSI_DIAG_DIR
#define GSI_DIAG_DIR "/data"
#endif
#ifndef GSI_SUP_LOG_PATH
#define GSI_SUP_LOG_PATH "/data/zygote_exec.log"
#endif
#ifndef GSI_SNAP_LOGCAT_BIN
#define GSI_SNAP_LOGCAT_BIN "/system/bin/logcat"
#endif
#ifndef GSI_SNAP_DMESG_BIN
#define GSI_SNAP_DMESG_BIN "/system/bin/dmesg"
#endif
#ifndef GSI_SNAP_DUMPSYS_BIN
#define GSI_SNAP_DUMPSYS_BIN "/system/bin/dumpsys"
#endif
#ifndef GSI_SNAP_SERVICE_BIN
#define GSI_SNAP_SERVICE_BIN "/system/bin/service"
#endif
#ifndef GSI_SNAP_LOG_BIN
#define GSI_SNAP_LOG_BIN "/system/bin/log"
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

/* 6.18: supervisor-owned diagnostics. The supervisor (see the
 * loop in main) now owns the continuous logcat capture, a
 * heartbeat with system_server aliveness, death snapshots, and
 * a best-effort tracefs signal tracer. Everything here is
 * fail-soft: any failure logs one line and the boot continues
 * exactly as 6.17. Children are tracked by pid explicitly;
 * nothing in 6.18 ever calls waitpid(-1), which would steal a
 * capture/snapshot child's status. */
static char gsi18_cap_path[1024];
static char gsi18_hb_path[1024];
static char gsi18_trace_root[1024];
static int gsi18_trace_ok = 0;
static pid_t gsi18_cap_pid = -1;
static int gsi18_cap_restarts = 0;
static int gsi18_cap_given_up = 0;
static time_t gsi18_cap_last_try = 0;
static time_t gsi18_t_first = 0;
static time_t gsi18_last_beat = 0;
static int gsi18_stuck_done = 0;
/* 6.19: tracer verification state (read-backs, not hopes). */
static int gsi18_trace_generate_ok = 0;
static int gsi18_trace_filter_ok = 0;
static int gsi18_trace_tracing_on_ok = 0;
static int gsi18_trace_sched_ok = 0;
static char gsi18_trace_pipe_path[1024];
static pid_t gsi18_tracepipe_pid = -1;
static time_t gsi18_tracepipe_last_try = 0;
/* 6.19: order-of-death + cgroup records. */
static char gsi18_zygote_cgroup[512];
static char gsi18_ss_cgroup[512];
static pid_t gsi18_ss_pid = -1;
static int gsi18_ss_pidfd = -1;
static int gsi18_z_pidfd = -1;
static int gsi18_ss_done = 0;
static long long gsi18_z_exit_bt = -1;
static long long gsi18_ss_exit_bt = -1;

/* Forward declaration: defined below the tracer (snapshot
 * section uses the tail-copy helper). */
static void gsi18_copy_tail(FILE *out, const char *path, int keep);

/* Read a small pseudo-file into buf (NUL-terminated, trailing
 * whitespace trimmed). Returns 1 on success, 0 on failure. */
static int gsi18_read_small_file(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY);
    ssize_t n;
    size_t len;
    if (fd < 0) return 0;
    n = read(fd, buf, cap - 1);
    close(fd);
    if (n < 0) return 0;
    len = (size_t)n;
    buf[len] = '\0';
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r' ||
                       buf[len - 1] == ' ' || buf[len - 1] == '\t')) {
        buf[--len] = '\0';
    }
    return 1;
}

/* Record /proc/<pid>/cgroup (newlines folded to ';') into buf. */
static void gsi18_read_proc_cgroup(pid_t pid, char *buf, size_t cap) {
    char path[128];
    int fd;
    ssize_t n;
    size_t i;
    snprintf(path, sizeof(path), "/proc/%d/cgroup", (int)pid);
    buf[0] = '\0';
    fd = open(path, O_RDONLY);
    if (fd < 0) return;
    n = read(fd, buf, cap - 1);
    close(fd);
    if (n <= 0) {
        buf[0] = '\0';
        return;
    }
    buf[n] = '\0';
    for (i = 0; buf[i]; i++) {
        if (buf[i] == '\n') buf[i] = ';';
    }
    /* Drop a trailing ';' from the final newline. */
    {
        size_t len = strlen(buf);
        if (len > 0 && buf[len - 1] == ';') buf[len - 1] = '\0';
    }
}

static void gsi18_sup_log(const char *fmt, ...) {
    FILE *lg = fopen(GSI_SUP_LOG_PATH, "a");
    if (!lg) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(lg, fmt, ap);
    va_end(ap);
    fclose(lg);
}

static void gsi18_msleep(unsigned ms) {
    struct timespec ts;
    ts.tv_sec = (time_t)(ms / 1000);
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {
    }
}

static unsigned gsi18_poll_ms(void) {
#ifdef GSI_ZYGOTE_TEST_TARGET
    const char *e = getenv("GSI_TEST_POLL_MS");
    if (e) {
        int v = atoi(e);
        if (v >= 10 && v <= 1000) return (unsigned)v;
    }
#endif
    return 250;
}

static unsigned gsi18_heartbeat_secs(void) {
#ifdef GSI_ZYGOTE_TEST_TARGET
    const char *e = getenv("GSI_TEST_HEARTBEAT_SECS");
    if (e) {
        int v = atoi(e);
        if (v >= 1 && v <= 60) return (unsigned)v;
    }
#endif
    return 5;
}

static long gsi18_stuck_delay_secs(void) {
#ifdef GSI_ZYGOTE_TEST_TARGET
    const char *e = getenv("GSI_TEST_STUCK_DELAY");
    if (e) {
        int v = atoi(e);
        if (v >= 1 && v <= 600) return (long)v;
    }
#endif
    return 60;
}

static int gsi18_write_small_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    size_t n = strlen(content);
    ssize_t w = write(fd, content, n);
    close(fd);
    return (w == (ssize_t)n) ? 0 : -1;
}

/* 6.19: enable ONLY the killer-naming event. signal_generate
 * is the event that names the sender: the task prefix on the
 * line is the sender, and its comm=/pid= fields are the
 * victim. signal_deliver records receiver-side fields only
 * (sig/errno/code/handler/flags) and CANNOT name a sender —
 * the 6.18 comment claiming otherwise was wrong, and 6.18
 * treated signal_deliver as the required event while
 * signal_generate was best-effort and never verified, yet
 * logged TRACEFS_OK anyway. 6.19 verifies every write by
 * read-back: signal_generate enable == 1, filter contains
 * SIGABRT/SIGKILL/SIGSEGV/SIGTERM (6.26: sig==9-only was blind
 * to the zygote's own SIGABRT death and to system_server's
 * unknown death signal), tracing_on == 1. sched_process_exit is best-effort
 * (exit events for the order-of-death cross-check).
 * signal_deliver is explicitly DISABLED so a stale enable
 * from an earlier run cannot flood the buffer with
 * receiver-side noise. Logs nothing itself; the caller logs
 * the outcome + read-backs. */
static int gsi18_enable_tracefs(void) {
    const char *roots[3];
    int nroots = 0;
    int i;
#ifdef GSI_ZYGOTE_TEST_TARGET
    {
        const char *tr = getenv("GSI_TEST_TRACEFS_ROOT");
        if (tr && *tr) roots[nroots++] = tr;
    }
#endif
    roots[nroots++] = "/sys/kernel/debug/tracing";
    roots[nroots++] = "/sys/kernel/tracing";
    gsi18_trace_generate_ok = 0;
    gsi18_trace_filter_ok = 0;
    gsi18_trace_tracing_on_ok = 0;
    gsi18_trace_sched_ok = 0;
    gsi18_trace_root[0] = '\0';
    gsi18_trace_ok = 0;
    for (i = 0; i < nroots; i++) {
        char p[1120];
        char rb[256];
        /* Silence the receiver-side event first. */
        snprintf(p, sizeof(p), "%s/events/signal/signal_deliver/enable", roots[i]);
        if (access(p, W_OK) != 0) continue;
        (void)gsi18_write_small_file(p, "0");
        snprintf(p, sizeof(p), "%s/events/signal/signal_generate/enable", roots[i]);
        if (gsi18_write_small_file(p, "1") != 0) continue;
        if (!gsi18_read_small_file(p, rb, sizeof(rb)) || strcmp(rb, "1") != 0) continue;
        gsi18_trace_generate_ok = 1;
        snprintf(p, sizeof(p), "%s/events/signal/signal_generate/filter", roots[i]);
        /* 6.26: fatal-signal filter. sig==9-only was blind to the
         * actual deaths: the zygote dies by SIGABRT (6), and
         * system_server's death signal is unknown. Capture
         * SIGABRT/SIGKILL/SIGSEGV/SIGTERM. Read-back must contain
         * all four tokens (space-stripped, since tracefs may
         * normalize spacing): on real tracefs a filter write
         * REPLACES the filter, so a stale single-condition tail
         * fails the all-four check instead of passing. */
        rb[0] = '\0';
        if (gsi18_write_small_file(p, "sig==6 || sig==9 || sig==11 || sig==15") == 0 &&
            gsi18_read_small_file(p, rb, sizeof(rb))) {
            char nosp[256];
            size_t ni = 0, ri;
            for (ri = 0; rb[ri] && ni + 1 < sizeof(nosp); ri++) {
                if (rb[ri] != ' ' && rb[ri] != '\t') nosp[ni++] = rb[ri];
            }
            nosp[ni] = '\0';
            if (strstr(nosp, "sig==6") && strstr(nosp, "sig==9") &&
                strstr(nosp, "sig==11") && strstr(nosp, "sig==15")) {
                gsi18_trace_filter_ok = 1;
            } else {
                gsi18_sup_log("[gsi_zygote_exec] TRACEFS_FILTER_MISMATCH readback='%s'\n", rb);
            }
        } else {
            gsi18_sup_log("[gsi_zygote_exec] TRACEFS_FILTER_UNREADABLE readback='%s'\n", rb);
        }
        snprintf(p, sizeof(p), "%s/events/sched/sched_process_exit/enable", roots[i]);
        if (gsi18_write_small_file(p, "1") == 0 &&
            gsi18_read_small_file(p, rb, sizeof(rb)) && strcmp(rb, "1") == 0) {
            gsi18_trace_sched_ok = 1;
        }
        snprintf(p, sizeof(p), "%s/tracing_on", roots[i]);
        if (gsi18_write_small_file(p, "1") == 0 &&
            gsi18_read_small_file(p, rb, sizeof(rb)) && strcmp(rb, "1") == 0) {
            gsi18_trace_tracing_on_ok = 1;
        }
        snprintf(gsi18_trace_root, sizeof(gsi18_trace_root), "%s", roots[i]);
        gsi18_trace_ok = (gsi18_trace_generate_ok && gsi18_trace_filter_ok &&
                          gsi18_trace_tracing_on_ok) ? 1 : 0;
        return gsi18_trace_ok;
    }
    return 0;
}

/* 6.19: re-assert the tracer every heartbeat tick. Other
 * tracers (Perfetto, Samsung) can reset tracefs events and
 * tracing_on mid-run; re-running the enable sequence is
 * cheap and idempotent. Logs the read-back values every tick,
 * so the bundle proves whether events were recording. */
static void gsi18_reassert_tracefs(void) {
    int ok = gsi18_enable_tracefs();
    gsi18_sup_log("[gsi_zygote_exec] TRACEFS_REASSERT ok=%d generate=%d filter=%d sched=%d tracing_on=%d root=%s\n",
                  ok, gsi18_trace_generate_ok, gsi18_trace_filter_ok,
                  gsi18_trace_sched_ok, gsi18_trace_tracing_on_ok,
                  gsi18_trace_root[0] ? gsi18_trace_root : "(none)");
}

/* 6.19: separate trace_pipe reader child. It blocks on
 * <root>/trace_pipe and appends every chunk to the /data pipe
 * log with a per-chunk fsync, so a kill record survives even
 * if the supervisor dies. Exits on EOF (tracing off + drained)
 * or via PR_SET_PDEATHSIG when the supervisor dies. */
static pid_t gsi18_start_tracepipe(void) {
    pid_t c;
    if (!gsi18_trace_root[0]) return -1;
    c = fork();
    if (c == 0) {
        char tp[1120];
        int tfd, ofd;
        (void)prctl(PR_SET_PDEATHSIG, SIGKILL);
        if (getppid() == 1) _exit(127);
        snprintf(tp, sizeof(tp), "%s/trace_pipe", gsi18_trace_root);
        tfd = open(tp, O_RDONLY);
        if (tfd < 0) _exit(127);
        ofd = open(gsi18_trace_pipe_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (ofd < 0) _exit(127);
        for (;;) {
            char buf[4096];
            ssize_t n = read(tfd, buf, sizeof(buf));
            ssize_t off;
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (n == 0) break;
            off = 0;
            while (off < n) {
                ssize_t w = write(ofd, buf + off, (size_t)(n - off));
                if (w < 0) {
                    if (errno == EINTR) continue;
                    break;
                }
                off += w;
            }
            (void)fsync(ofd);
        }
        (void)fsync(ofd);
        close(ofd);
        close(tfd);
        _exit(0);
    }
    if (c < 0) return -1;
    gsi18_sup_log("[gsi_zygote_exec] TRACEPIPE_STARTED: pid=%d path=%s\n",
                  (int)c, gsi18_trace_pipe_path);
    return c;
}

/* 6.19: at death, tracing goes off FIRST — before any read —
 * so the kill record cannot be overwritten between the death
 * and the snapshot. Waits briefly for the reader to drain +
 * exit on EOF, then stops it if it is stuck. */
static void gsi18_trace_off_first(void) {
    char p[1120];
    char rb[64];
    if (!gsi18_trace_root[0]) return;
    snprintf(p, sizeof(p), "%s/tracing_on", gsi18_trace_root);
    (void)gsi18_write_small_file(p, "0");
    gsi18_msleep(250);
    if (gsi18_tracepipe_pid > 0) {
        int st = 0;
        pid_t w = waitpid(gsi18_tracepipe_pid, &st, WNOHANG);
        if (w == 0) {
            gsi18_sup_log("[gsi_zygote_exec] KILL_PID caller=tracepipe_stop pid=%d time=%lld\n",
                          (int)gsi18_tracepipe_pid, (long long)time(NULL));
            (void)kill(gsi18_tracepipe_pid, SIGKILL);
            (void)waitpid(gsi18_tracepipe_pid, &st, 0);
        }
        gsi18_tracepipe_pid = -1;
    }
    /* Logged unconditionally (not only when a reader was
     * alive): the read-back is the evidence tracing went off
     * before the snapshot read. */
    if (gsi18_read_small_file(p, rb, sizeof(rb))) {
        gsi18_sup_log("[gsi_zygote_exec] TRACE_OFF: tracing_on=%s (written 0 first, reader stopped)\n", rb);
    } else {
        gsi18_sup_log("[gsi_zygote_exec] TRACE_OFF: tracing_on=(unreadable after write)\n");
    }
}

/* 6.19: snapshot trace evidence. The 6.18 tail-100 of
 * <root>/trace was unfiltered receiver-side noise read late
 * without ever switching tracing off. Now: the trace header
 * line (entries-in-buffer/entries-written — proves whether
 * events recorded at all) + the tail of the trace_pipe
 * reader log (signal_generate fatal-signal sender lines). The
 * parent writes tracing_on=0 BEFORE forking the snapshot, so
 * the buffer cannot be overwritten between death and read. */
static void gsi18_dump_trace_tail(FILE *out) {
    char p[1120];
    FILE *f;
    char buf[1024];
    int found = 0;
    int lines = 0;
    if (!gsi18_trace_root[0]) {
        fprintf(out, "(tracer not enabled — no tracing root)\n");
        return;
    }
    fprintf(out, "--- trace header (entries-in-buffer/entries-written) ---\n");
    snprintf(p, sizeof(p), "%s/trace", gsi18_trace_root);
    f = fopen(p, "r");
    if (f) {
        while (fgets(buf, sizeof(buf), f) && lines < 12) {
            lines++;
            if (strstr(buf, "entries-in-buffer") != NULL) {
                fputs(buf, out);
                found = 1;
                break;
            }
        }
        if (!found) {
            fprintf(out, "(no entries-in-buffer header in first 12 lines — tracing may be off or the buffer empty)\n");
        }
        fclose(f);
    } else {
        fprintf(out, "(trace unreadable: %s)\n", strerror(errno));
    }
    fprintf(out, "--- trace_pipe log (signal_generate fatal-signal, last 100) ---\n");
    if (gsi18_trace_pipe_path[0]) {
        gsi18_copy_tail(out, gsi18_trace_pipe_path, 100);
    } else {
        fprintf(out, "(no trace_pipe log — reader never started)\n");
    }
}

/* 6.19: memory-killer state at death. The oom_kill counter in
 * /proc/vmstat + /proc/pressure/memory + MemAvailable: if the
 * oom_kill counter did not move and pressure is low, neither
 * the kernel OOM killer nor lmkd pressure explains the death.
 * Direct reads, no tools, never fatal. */
static void gsi18_dump_memkiller(FILE *out) {
    FILE *f;
    char buf[512];
    fprintf(out, "--- oom_kill counter (/proc/vmstat) ---\n");
    f = fopen("/proc/vmstat", "r");
    if (f) {
        while (fgets(buf, sizeof(buf), f)) {
            if (strncmp(buf, "oom_kill", 8) == 0) {
                fputs(buf, out);
                break;
            }
        }
        fclose(f);
    } else {
        fprintf(out, "(vmstat unreadable: %s)\n", strerror(errno));
    }
    fprintf(out, "--- memory pressure (/proc/pressure/memory) ---\n");
    f = fopen("/proc/pressure/memory", "r");
    if (f) {
        while (fgets(buf, sizeof(buf), f)) fputs(buf, out);
        fclose(f);
    } else {
        fprintf(out, "(pressure unreadable: %s)\n", strerror(errno));
    }
    fprintf(out, "--- MemAvailable (/proc/meminfo) ---\n");
    f = fopen("/proc/meminfo", "r");
    if (f) {
        while (fgets(buf, sizeof(buf), f)) {
            if (strncmp(buf, "MemTotal:", 9) == 0 ||
                strncmp(buf, "MemFree:", 8) == 0 ||
                strncmp(buf, "MemAvailable:", 13) == 0) {
                fputs(buf, out);
            }
        }
        fclose(f);
    } else {
        fprintf(out, "(meminfo unreadable: %s)\n", strerror(errno));
    }
}

/* Find system_server by scanning /proc: cmdline first token,
 * /proc/<pid>/stat comm as fallback. Skips this process.
 * Returns the pid, or -1. Never fails the boot. */
static pid_t gsi18_find_system_server(void) {
    DIR *d = opendir("/proc");
    struct dirent *de;
    pid_t self = getpid();
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        pid_t pid;
        char path[128];
        FILE *f;
        char buf[512];
        size_t n;
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        pid = (pid_t)atoi(de->d_name);
        if (pid <= 0 || pid == self) continue;
        snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
        f = fopen(path, "r");
        if (f) {
            n = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            if (n > 0) {
                buf[n] = '\0';
                if (strcmp(buf, "system_server") == 0) {
                    closedir(d);
                    return pid;
                }
            }
        }
        snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
        f = fopen(path, "r");
        if (f) {
            if (fgets(buf, sizeof(buf), f)) {
                if (strstr(buf, "(system_server)") != NULL) {
                    fclose(f);
                    closedir(d);
                    return pid;
                }
            }
            fclose(f);
        }
    }
    closedir(d);
    return -1;
}

/* Stuck-boot snapshot: per-thread wchan + kernel stack for
 * system_server. Each thread is independent: a denial on one
 * is logged for that thread and the rest still snapshot. */
static void gsi18_snapshot_stacks(pid_t ss_pid, const char *out_path) {
    FILE *out = fopen(out_path, "w");
    char taskdir[128];
    DIR *d;
    struct dirent *de;
    int nthreads = 0;
    if (!out) return;
    fprintf(out, "GSI_STUCK_SNAPSHOT system_server=%d at=%lld\n",
            (int)ss_pid, (long long)time(NULL));
    snprintf(taskdir, sizeof(taskdir), "/proc/%d/task", (int)ss_pid);
    d = opendir(taskdir);
    if (!d) {
        fprintf(out, "task dir unreadable: %s\n", strerror(errno));
        fclose(out);
        return;
    }
    while ((de = readdir(d)) != NULL && nthreads < 128) {
        char p[192];
        FILE *f;
        char b[512];
        int nl;
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        nthreads++;
        fprintf(out, "--- thread %s ---\n", de->d_name);
        snprintf(p, sizeof(p), "/proc/%d/task/%s/wchan", (int)ss_pid, de->d_name);
        f = fopen(p, "r");
        if (f) {
            if (fgets(b, sizeof(b), f)) {
                size_t L = strlen(b);
                while (L > 0 && (b[L - 1] == '\n' || b[L - 1] == '\r')) b[--L] = '\0';
                fprintf(out, "wchan: %s\n", b[0] ? b : "(empty)");
            } else {
                fprintf(out, "wchan: (empty)\n");
            }
            fclose(f);
        } else {
            fprintf(out, "wchan: (denied: %s)\n", strerror(errno));
        }
        snprintf(p, sizeof(p), "/proc/%d/task/%s/stack", (int)ss_pid, de->d_name);
        f = fopen(p, "r");
        if (f) {
            nl = 0;
            while (nl < 24 && fgets(b, sizeof(b), f)) {
                fputs(b, out);
                nl++;
            }
            if (nl == 0) fprintf(out, "(empty stack)\n");
            fclose(f);
        } else {
            fprintf(out, "stack: (denied: %s)\n", strerror(errno));
        }
    }
    closedir(d);
    fprintf(out, "threads: %d\n", nthreads);
    fclose(out);
}

/* Wait for pid up to timeout_ms; on expiry SIGKILL it and
 * reap it. Returns 1 reaped normally, 0 killed on timeout,
 * -1 on wait error. */
static int gsi18_wait_timeout(pid_t pid, int *status, unsigned timeout_ms) {
    unsigned waited = 0;
    for (;;) {
        pid_t w = waitpid(pid, status, WNOHANG);
        if (w == pid) return 1;
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (waited >= timeout_ms) {
            /* 6.19: PID-targeted by construction (tracked pid);
             * log caller + time on every kill. */
            gsi18_sup_log("[gsi_zygote_exec] KILL_PID caller=wait_timeout pid=%d time=%lld\n",
                          (int)pid, (long long)time(NULL));
            (void)kill(pid, SIGKILL);
            {
                pid_t w2;
                do {
                    w2 = waitpid(pid, status, 0);
                } while (w2 < 0 && errno == EINTR);
            }
            return 0;
        }
        gsi18_msleep(100);
        waited += 100;
    }
}

/* Copy the last keep lines of path into out. */
static void gsi18_copy_tail(FILE *out, const char *path, int keep) {
    FILE *f = fopen(path, "r");
    char **ring;
    char buf[1024];
    int idx = 0, total = 0, i;
    if (!f) return;
    ring = (char **)calloc((size_t)keep, sizeof(char *));
    if (!ring) {
        fclose(f);
        return;
    }
    while (fgets(buf, sizeof(buf), f)) {
        size_t len = strlen(buf);
        char *copy = (char *)malloc(len + 1);
        if (!copy) break;
        memcpy(copy, buf, len + 1);
        free(ring[idx % keep]);
        ring[idx % keep] = copy;
        idx++;
        total++;
    }
    fclose(f);
    {
        int start = total > keep ? total - keep : 0;
        for (i = start; i < total; i++) {
            if (ring[i % keep]) fputs(ring[i % keep], out);
        }
    }
    for (i = 0; i < keep; i++) free(ring[i]);
    free(ring);
}

/* Run one dump tool (logcat/dmesg) into a temp file, then copy
 * its tail into the snapshot. No shell, no pipes: the tool
 * cannot block on a full pipe, and a timeout kills it cleanly. */
static void gsi18_run_tool_to_file(FILE *out, const char *bin,
                                   char *const argv[], const char *tmp_path,
                                   unsigned timeout_ms, int keep_lines) {
    int fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    pid_t c;
    int status = 0;
    int r;
    if (fd < 0) {
        fprintf(out, "(tmp open failed for %s: %s)\n", bin, strerror(errno));
        return;
    }
    c = fork();
    if (c == 0) {
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) {
            (void)dup2(dn, 0);
            if (dn > 2) close(dn);
        }
        (void)dup2(fd, 1);
        (void)dup2(fd, 2);
        if (fd > 2) close(fd);
        {
            int fdi;
            for (fdi = 3; fdi < 64; fdi++) close(fdi);
        }
        execv(bin, argv);
        _exit(127);
    }
    close(fd);
    if (c < 0) {
        fprintf(out, "(fork failed for %s: %s)\n", bin, strerror(errno));
        unlink(tmp_path);
        return;
    }
    r = gsi18_wait_timeout(c, &status, timeout_ms);
    if (r == 0) {
        fprintf(out, "(tool timed out, killed: %s)\n", bin);
    } else if (r < 0) {
        fprintf(out, "(tool wait failed: %s)\n", bin);
    } else if (WIFEXITED(status) && WEXITSTATUS(status) == 127) {
        fprintf(out, "(tool exec failed: %s)\n", bin);
    }
    gsi18_copy_tail(out, tmp_path, keep_lines);
    unlink(tmp_path);
}

/* 6.19: vold ownership probe. The guest system_server died
 * at least once by its own Java crash in the vold CE-key path
 * (LockSettingsService.setCeStorageProtection <- vold
 * ServiceSpecificException), and the two-vold hypothesis says
 * the guest talks to the HOST vold through the shared
 * servicemanager. This probe names the vold instances alive
 * at death (pid + ppid + argv[0]) and records what the
 * servicemanager answers for the `vold` name, so the next
 * bundle shows which instance owns it. Classification only;
 * no vold fix is attempted here. HARD RULE (Claude #3):
 * nothing in this file forces, bypasses, retry-spoofs, or
 * patches around setCeStorageProtection or the CE-key
 * migration in any way — guest user 0 == host user 0 and
 * both volds share the `vold` binder name, so a forced
 * success could re-wrap the REAL CE key or touch
 * gatekeeper/weaver state. vold refusing may be what
 * protects the phone. This probe only READS. NOTE: whether this build's
 * dumpsys accepts `--pid` is unverified on-device; if it
 * does not, its usage error is itself diagnostic and is
 * captured below. */
static void gsi18_dump_vold_probe(FILE *out) {
    DIR *d;
    struct dirent *de;
    char plist[256];
    size_t plen = 0;
    int any = 0;
    fprintf(out, "--- vold processes (comm==vold) ---\n");
    plist[0] = '\0';
    d = opendir("/proc");
    if (d) {
        while ((de = readdir(d)) != NULL) {
            pid_t pid;
            char spath[128];
            FILE *f;
            char sbuf[512];
            char *lp, *rp;
            int ppid = -1;
            char cmd[160];
            int cfd;
            ssize_t cn;
            if (!isdigit((unsigned char)de->d_name[0])) continue;
            pid = (pid_t)atoi(de->d_name);
            if (pid <= 1 || pid == getpid()) continue;
            snprintf(spath, sizeof(spath), "/proc/%d/stat", (int)pid);
            f = fopen(spath, "r");
            if (!f) continue;
            if (!fgets(sbuf, sizeof(sbuf), f)) {
                fclose(f);
                continue;
            }
            fclose(f);
            lp = strchr(sbuf, '(');
            rp = strrchr(sbuf, ')');
            if (!lp || !rp || rp <= lp) continue;
            if ((rp - lp - 1) != 4 || memcmp(lp + 1, "vold", 4) != 0) continue;
            if (sscanf(rp + 1, " %*c %d", &ppid) != 1) ppid = -1;
            cmd[0] = '\0';
            snprintf(spath, sizeof(spath), "/proc/%d/cmdline", (int)pid);
            cfd = open(spath, O_RDONLY);
            if (cfd >= 0) {
                cn = read(cfd, cmd, sizeof(cmd) - 1);
                close(cfd);
                if (cn > 0) {
                    cmd[cn] = '\0';
                } else {
                    cmd[0] = '\0';
                }
            }
            fprintf(out, "VOLD_PID pid=%d ppid=%d argv0=%s\n",
                    (int)pid, ppid, cmd[0] ? cmd : "(empty)");
            if (plen + 16 < sizeof(plist)) {
                plen += (size_t)snprintf(plist + plen, sizeof(plist) - plen,
                                         "%d ", (int)pid);
            }
            any = 1;
        }
        closedir(d);
    }
    fprintf(out, "VOLD_PIDS: %s\n", any ? plist : "(none)");
    fprintf(out, "--- dumpsys --pid vold (which process owns the vold binder name?) ---\n");
    fflush(out);
    {
        char tmp[1120];
        char *args[] = {"dumpsys", "--pid", "vold", NULL};
        snprintf(tmp, sizeof(tmp), "%s/.gsi_snap_dumpsys.tmp", GSI_DIAG_DIR);
        gsi18_run_tool_to_file(out, GSI_SNAP_DUMPSYS_BIN, args, tmp, 4000, 20);
    }
    fprintf(out, "--- service check vold ---\n");
    fflush(out);
    {
        char tmp[1120];
        char *args[] = {"service", "check", "vold", NULL};
        snprintf(tmp, sizeof(tmp), "%s/.gsi_snap_svc.tmp", GSI_DIAG_DIR);
        gsi18_run_tool_to_file(out, GSI_SNAP_SERVICE_BIN, args, tmp, 2000, 5);
    }
}

/* Snapshot child: dumps logcat -d, dmesg, and the tracefs tail
 * into snap_path, then exits. Runs in its own fork so a stuck
 * tool can never stall the supervisor. */
static void gsi18_snapshot_child(const char *snap_path) {
    FILE *out;
    char tmp[1120];
    int dn = open("/dev/null", O_RDWR);
    if (dn >= 0) {
        (void)dup2(dn, 0);
        (void)dup2(dn, 1);
        (void)dup2(dn, 2);
        if (dn > 2) close(dn);
    }
    {
        int fdi;
        for (fdi = 3; fdi < 64; fdi++) close(fdi);
    }
    out = fopen(snap_path, "w");
    if (!out) _exit(2);
    fprintf(out, "GSI_DEATH_SNAPSHOT at=%lld\n", (long long)time(NULL));
    fprintf(out, "=== logcat -d -b all (last 500) ===\n");
    fflush(out);
    {
        char *args[] = {"logcat", "-d", "-b", "all", "-t", "500", NULL};
        snprintf(tmp, sizeof(tmp), "%s/.gsi_snap_logcat.tmp", GSI_DIAG_DIR);
        gsi18_run_tool_to_file(out, GSI_SNAP_LOGCAT_BIN, args, tmp, 8000, 500);
    }
    fprintf(out, "=== dmesg (last 300) ===\n");
    fflush(out);
    {
        char *args[] = {"dmesg", NULL};
        snprintf(tmp, sizeof(tmp), "%s/.gsi_snap_dmesg.tmp", GSI_DIAG_DIR);
        gsi18_run_tool_to_file(out, GSI_SNAP_DMESG_BIN, args, tmp, 8000, 300);
    }
    fprintf(out, "=== tracefs evidence (6.19: header + trace_pipe) ===\n");
    fflush(out);
    gsi18_dump_trace_tail(out);
    fprintf(out, "=== memory-killer state (6.19) ===\n");
    fflush(out);
    gsi18_dump_memkiller(out);
    fprintf(out, "=== cgroup (6.19) ===\n");
    fflush(out);
    fprintf(out, "zygote: %s\n", gsi18_zygote_cgroup[0] ? gsi18_zygote_cgroup : "(not recorded)");
    fprintf(out, "system_server: %s\n", gsi18_ss_cgroup[0] ? gsi18_ss_cgroup : "(not recorded)");
    fprintf(out, "=== vold ownership probe (6.19) ===\n");
    fflush(out);
    gsi18_dump_vold_probe(out);
    fclose(out);
    _exit(0);
}

/* 6.19: order-of-death wording shared by the wait loop log
 * and the classification section. */
static const char *gsi18_order_str(void) {
    long long zd = gsi18_z_exit_bt;
    long long sd = gsi18_ss_exit_bt;
    if (zd < 0 || sd < 0) return "UNKNOWN";
    if (zd - sd > 500) return "SS_FIRST";
    if (sd - zd > 500) return "ZYGOTE_FIRST";
    return "TOGETHER";
}

/* 6.19: death classification. The snapshot child already
 * wrote logcat + dmesg + trace + probe sections; the parent
 * scans the finished file and appends the verdict, so the
 * next bundle tells us HOW MANY deaths are vold-fatals vs
 * true SIGKILLs without re-reading raw logs. Precedence is
 * deliberate: a CE-key Java fatal is the CAUSE even when the
 * file also holds SIGKILL report lines (zygote reporting its
 * dead system_server); a file with SIGKILL lines and no Java
 * fatal is a true SIGKILL. Classification only — no vold
 * fix is attempted in 6.19. HARD RULE (Claude #3): this
 * function only READS log lines. It never forces, bypasses,
 * or patches the CE-key path — a forced setCeStorageProtection
 * success could re-wrap the host's real CE key. */
static void gsi18_append_death_meta(const char *path, int attempt) {
    FILE *f = fopen(path, "r");
    char line[1024];
    int sawCe = 0, sawFatal = 0, sawSig9 = 0;
    char firstFatal[320];
    char voldPids[256];
    const char *cls;
    FILE *out;
    firstFatal[0] = '\0';
    voldPids[0] = '\0';
    if (f) {
        while (fgets(line, sizeof(line), f)) {
            if (strstr(line, "Failed to protect CE key for user 0") != NULL) sawCe = 1;
            if (strstr(line, "FATAL EXCEPTION") != NULL) sawFatal = 1;
            if (strstr(line, "exited due to signal 9") != NULL ||
                strstr(line, "signal 9 (Killed)") != NULL ||
                strstr(line, "Fatal signal 9") != NULL) sawSig9 = 1;
            if (!firstFatal[0] &&
                (strstr(line, "FATAL EXCEPTION") != NULL ||
                 strstr(line, "Fatal signal") != NULL ||
                 strstr(line, "exited due to signal") != NULL)) {
                size_t n = strlen(line);
                while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
                if (n > (int)sizeof(firstFatal) - 1) n = sizeof(firstFatal) - 1;
                memcpy(firstFatal, line, n);
                firstFatal[n] = '\0';
            }
            if (!voldPids[0] && strncmp(line, "VOLD_PIDS:", 10) == 0) {
                size_t n = strlen(line);
                while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
                if (n > (int)sizeof(voldPids) - 1) n = sizeof(voldPids) - 1;
                memcpy(voldPids, line, n);
                voldPids[n] = '\0';
            }
        }
        fclose(f);
    }
    if (sawCe && sawFatal) cls = "VOLD_CE_FATAL";
    else if (sawSig9) cls = "SIGKILL";
    else if (sawFatal) cls = "JAVA_FATAL";
    else cls = "OTHER";
    out = fopen(path, "a");
    if (out) {
        fprintf(out, "=== 6.19 death classification ===\n");
        fprintf(out, "DEATH_CLASS=%s\n", cls);
        fprintf(out, "DEATH_FIRST_FATAL=%s\n",
                firstFatal[0] ? firstFatal : "(no fatal line in snapshot)");
        fprintf(out, "DEATH_ORDER order=%s zygote_bt_ms=%lld system_server_bt_ms=%lld\n",
                gsi18_order_str(), gsi18_z_exit_bt, gsi18_ss_exit_bt);
        fprintf(out, "TRACE_STATE generate=%d filter=%d sched=%d tracing_on=%d (last heartbeat reassert read-backs)\n",
                gsi18_trace_generate_ok, gsi18_trace_filter_ok,
                gsi18_trace_sched_ok, gsi18_trace_tracing_on_ok);
        if (voldPids[0]) fprintf(out, "%s\n", voldPids);
        fclose(out);
    }
    gsi18_sup_log("[gsi_zygote_exec] DEATH_CLASS attempt=%d class=%s order=%s\n",
                  attempt, cls, gsi18_order_str());
}

/* Death snapshot: fork the snapshot child, wait up to 25 s,
 * log the outcome + byte size. Fail-soft, always. */
static void gsi18_take_death_snapshot(int attempt, long long epoch) {
    char path[1120];
    pid_t c;
    int status = 0;
    int r;
    struct stat st;
    long sz = -1;
    snprintf(path, sizeof(path), "%s/gsi_death_%d_%lld.log",
             GSI_DIAG_DIR, attempt, epoch);
    c = fork();
    if (c == 0) {
        gsi18_snapshot_child(path);
        _exit(0);
    }
    if (c < 0) {
        gsi18_sup_log("[gsi_zygote_exec] SNAPSHOT_FORK_FAILED: attempt=%d (%s)\n",
                      attempt, strerror(errno));
        return;
    }
    r = gsi18_wait_timeout(c, &status, 25000);
    /* 6.19: classify + annotate before measuring, so the logged
     * byte count covers the finished file. */
    if (stat(path, &st) == 0 && st.st_size > 0) {
        gsi18_append_death_meta(path, attempt);
    }
    if (stat(path, &st) == 0) sz = (long)st.st_size;
    if (r == 1) {
        gsi18_sup_log("[gsi_zygote_exec] SNAPSHOT_OK: attempt=%d path=%s bytes=%ld\n",
                      attempt, path, sz);
    } else if (r == 0) {
        gsi18_sup_log("[gsi_zygote_exec] SNAPSHOT_TIMEOUT: attempt=%d path=%s bytes=%ld (helper killed)\n",
                      attempt, path, sz);
    } else {
        gsi18_sup_log("[gsi_zygote_exec] SNAPSHOT_WAIT_FAILED: attempt=%d path=%s bytes=%ld\n",
                      attempt, path, sz);
    }
}

/* Start the supervisor-owned logcat capture. On a restart the
 * previous file is preserved as .restart<N> (latest 2 kept)
 * so a restart can never truncate the evidence the bundle
 * needs. Returns the child pid, or -1. */
static pid_t gsi18_start_capture(void) {
    pid_t c;
    if (gsi18_cap_restarts > 0) {
        char prev[1120];
        char old[1120];
        snprintf(prev, sizeof(prev), "%s.restart%d", gsi18_cap_path, gsi18_cap_restarts);
        (void)rename(gsi18_cap_path, prev);
        if (gsi18_cap_restarts > 2) {
            snprintf(old, sizeof(old), "%s.restart%d", gsi18_cap_path, gsi18_cap_restarts - 2);
            unlink(old);
        }
    }
    c = fork();
    if (c == 0) {
        int dn;
        (void)prctl(PR_SET_PDEATHSIG, SIGKILL);
        if (getppid() == 1) _exit(127);
        (void)setsid();
        dn = open("/dev/null", O_RDWR);
        if (dn >= 0) {
            (void)dup2(dn, 0);
            (void)dup2(dn, 1);
            (void)dup2(dn, 2);
            if (dn > 2) close(dn);
        }
        {
            int fdi;
            for (fdi = 3; fdi < 64; fdi++) close(fdi);
        }
        {
            char *args[] = {"logcat", "-b", "main", "-b", "system", "-b", "crash",
                            "-b", "events", "-v", "threadtime", "-f", gsi18_cap_path,
                            "-r", "1024", "-n", "4",
                            /* 6.19: name the low-memory killer in the
                             * capture. Unlisted tags still default to
                             * verbose; these specs pin the two killer
                             * tags visible at V. */
                            "lowmemorykiller:V", "lmkd:V", NULL};
            execv(GSI_SNAP_LOGCAT_BIN, args);
        }
        _exit(127);
    }
    if (c < 0) return -1;
    gsi18_cap_last_try = time(NULL);
    return c;
}

/* 6.19: pidfd + CLOCK_BOOTTIME order-of-death support. */
static long long gsi18_boottime_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0) return -1;
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000L;
}

static int gsi18_pidfd_open(pid_t pid) {
#ifdef SYS_pidfd_open
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    (void)pid;
    return -1;
#endif
}

/* Find the system_server whose parent is ppid_want — the
 * GUEST system_server forked by this attempt's zygote, not
 * the host's restarted one (same name, different parent). */
static pid_t gsi18_find_system_server_child(pid_t ppid_want) {
    DIR *d = opendir("/proc");
    struct dirent *de;
    pid_t self = getpid();
    pid_t found = -1;
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        pid_t pid;
        char path[128];
        FILE *f;
        char sbuf[512];
        char *lp, *rp;
        int ppid = -1;
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        pid = (pid_t)atoi(de->d_name);
        if (pid <= 1 || pid == self) continue;
        snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
        f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(sbuf, sizeof(sbuf), f)) {
            fclose(f);
            continue;
        }
        fclose(f);
        lp = strchr(sbuf, '(');
        rp = strrchr(sbuf, ')');
        if (!lp || !rp || rp <= lp) continue;
        if ((rp - lp - 1) != 13 || memcmp(lp + 1, "system_server", 13) != 0) continue;
        if (sscanf(rp + 1, " %*c %d", &ppid) != 1) continue;
        if (ppid == (int)ppid_want) {
            found = pid;
            break;
        }
    }
    closedir(d);
    return found;
}

/* One poll round over the death pidfds: stamp CLOCK_BOOTTIME
 * at each exit. Safe to call repeatedly; first stamp wins. */
static void gsi18_poll_deaths_once(void) {
    struct pollfd pfds[2];
    int nfds = 0;
    int zi = -1, si = -1;
    if (gsi18_z_pidfd >= 0) {
        zi = nfds;
        pfds[nfds].fd = gsi18_z_pidfd;
        pfds[nfds].events = POLLIN;
        pfds[nfds].revents = 0;
        nfds++;
    }
    if (gsi18_ss_pidfd >= 0) {
        si = nfds;
        pfds[nfds].fd = gsi18_ss_pidfd;
        pfds[nfds].events = POLLIN;
        pfds[nfds].revents = 0;
        nfds++;
    }
    if (nfds <= 0) return;
    if (poll(pfds, (nfds_t)nfds, 0) <= 0) return;
    if (zi >= 0 && (pfds[zi].revents & POLLIN) && gsi18_z_exit_bt < 0) {
        gsi18_z_exit_bt = gsi18_boottime_ms();
        gsi18_sup_log("[gsi_zygote_exec] ORDER_EVT who=zygote bt_ms=%lld\n", gsi18_z_exit_bt);
    }
    if (si >= 0 && (pfds[si].revents & POLLIN) && gsi18_ss_exit_bt < 0) {
        gsi18_ss_exit_bt = gsi18_boottime_ms();
        gsi18_ss_done = 1;
        gsi18_sup_log("[gsi_zygote_exec] ORDER_EVT who=system_server bt_ms=%lld\n", gsi18_ss_exit_bt);
    }
}

/* 6.19: GSI_SUP log markers. The windowed extract anchors
 * between these instead of converting timestamps (the 6.18
 * conversion emptied 19 of 20 windows). Double-fork: the
 * middle child is reaped here by pid, the grandchild is
 * reparented to init — no waitpid(-1) anywhere. */
static void gsi18_log_marker(const char *msg) {
    pid_t c = fork();
    if (c == 0) {
        pid_t g = fork();
        if (g == 0) {
            int dn;
            /* NOTE: no PR_SET_PDEATHSIG here — the middle child
             * is MEANT to exit immediately, and a death-signal
             * would race-kill the grandchild before execl
             * (lost the first marker in the harness). The
             * grandchild execs /system/bin/log and exits on
             * its own in milliseconds. */
            dn = open("/dev/null", O_RDWR);
            if (dn >= 0) {
                (void)dup2(dn, 0);
                (void)dup2(dn, 1);
                (void)dup2(dn, 2);
                if (dn > 2) close(dn);
            }
            execl(GSI_SNAP_LOG_BIN, "log", "-t", "GSI_SUP", msg, (char *)NULL);
            _exit(127);
        }
        _exit(0);
    }
    if (c > 0) {
        int st = 0;
        (void)waitpid(c, &st, 0);
    }
}

/* Per-tick service: capture supervision (death + throttled
 * restart), heartbeat beats with system_server aliveness, and
 * the one-shot 60 s stuck-boot snapshot. Called from the
 * zygote wait poll loop (zygote_alive=1) and from backoff
 * sleeps (zygote_alive=0: no stuck snapshot while no zygote
 * is running). Never blocks, never fails the boot. */
static void gsi18_service(int zygote_alive) {
    time_t now = time(NULL);
    if (gsi18_cap_pid > 0) {
        int st = 0;
        pid_t w = waitpid(gsi18_cap_pid, &st, WNOHANG);
        if (w == gsi18_cap_pid) {
            if (WIFEXITED(st)) {
                gsi18_sup_log("[gsi_zygote_exec] CAPTURE_DIED: exit=%d restarts=%d\n",
                              WEXITSTATUS(st), gsi18_cap_restarts);
            } else if (WIFSIGNALED(st)) {
                gsi18_sup_log("[gsi_zygote_exec] CAPTURE_DIED: signal=%d restarts=%d\n",
                              WTERMSIG(st), gsi18_cap_restarts);
            } else {
                gsi18_sup_log("[gsi_zygote_exec] CAPTURE_DIED: status=%d restarts=%d\n",
                              st, gsi18_cap_restarts);
            }
            gsi18_cap_pid = -1;
        } else if (w < 0 && errno == ECHILD) {
            gsi18_sup_log("[gsi_zygote_exec] CAPTURE_DIED: unknown (already reaped) restarts=%d\n",
                          gsi18_cap_restarts);
            gsi18_cap_pid = -1;
        }
    }
    if (gsi18_cap_pid < 0 && !gsi18_cap_given_up) {
        if (gsi18_cap_restarts >= 10) {
            gsi18_cap_given_up = 1;
            gsi18_sup_log("[gsi_zygote_exec] CAPTURE_GIVE_UP: 10 restarts exhausted — capture stays down, boot continues\n");
        } else if (now - gsi18_cap_last_try >= 2) {
            pid_t np;
            gsi18_cap_restarts++;
            np = gsi18_start_capture();
            if (np > 0) {
                gsi18_cap_pid = np;
                gsi18_sup_log("[gsi_zygote_exec] CAPTURE_RESTARTED: pid=%d restarts=%d path=%s\n",
                              (int)np, gsi18_cap_restarts, gsi18_cap_path);
            } else {
                gsi18_cap_last_try = now;
                gsi18_sup_log("[gsi_zygote_exec] CAPTURE_START_FAILED: path=%s (%s) — retrying, boot continues\n",
                              gsi18_cap_path, strerror(errno));
            }
        }
    }
    /* 6.19: trace_pipe reader supervision — reap a dead
     * reader (EOF after tracing off, or PDEATHSIG) so the
     * restart below can replace it. */
    if (gsi18_tracepipe_pid > 0) {
        int st = 0;
        pid_t w = waitpid(gsi18_tracepipe_pid, &st, WNOHANG);
        if (w == gsi18_tracepipe_pid) {
            gsi18_sup_log("[gsi_zygote_exec] TRACEPIPE_DIED: pid=%d\n",
                          (int)gsi18_tracepipe_pid);
            gsi18_tracepipe_pid = -1;
        } else if (w < 0 && errno == ECHILD) {
            gsi18_tracepipe_pid = -1;
        }
    }
    if (gsi18_last_beat == 0 || now - gsi18_last_beat >= (time_t)gsi18_heartbeat_secs()) {
        /* 6.19: re-assert the tracer every heartbeat tick and
         * restart the pipe reader (throttled) when tracing is
         * verified on, so the next attempt is traced even if
         * another tracer reset tracefs between attempts. */
        gsi18_reassert_tracefs();
        if (gsi18_trace_ok && gsi18_tracepipe_pid < 0 &&
            now - gsi18_tracepipe_last_try >= 2) {
            pid_t tp;
            gsi18_tracepipe_last_try = now;
            tp = gsi18_start_tracepipe();
            if (tp > 0) gsi18_tracepipe_pid = tp;
        }
        pid_t ss = gsi18_find_system_server();
        FILE *hb = fopen(gsi18_hb_path, "a");
        gsi18_last_beat = now;
        if (hb) {
            if (ss > 0) {
                fprintf(hb, "BEAT t=%lld up=%lld system_server=%d capture=%d\n",
                        (long long)now,
                        gsi18_t_first ? (long long)(now - gsi18_t_first) : 0LL,
                        (int)ss, (int)gsi18_cap_pid);
            } else {
                fprintf(hb, "BEAT t=%lld up=%lld system_server=none capture=%d\n",
                        (long long)now,
                        gsi18_t_first ? (long long)(now - gsi18_t_first) : 0LL,
                        (int)gsi18_cap_pid);
            }
            fclose(hb);
        }
    }
    if (zygote_alive && !gsi18_stuck_done && gsi18_t_first != 0 &&
        now - gsi18_t_first >= gsi18_stuck_delay_secs()) {
        pid_t ss;
        gsi18_stuck_done = 1;
        ss = gsi18_find_system_server();
        if (ss > 0) {
            char p[1120];
            snprintf(p, sizeof(p), "%s/gsi_stuck_%lld.log", GSI_DIAG_DIR, (long long)now);
            gsi18_snapshot_stacks(ss, p);
            gsi18_sup_log("[gsi_zygote_exec] STUCK_SNAPSHOT: system_server=%d path=%s\n",
                          (int)ss, p);
        } else {
            gsi18_sup_log("[gsi_zygote_exec] STUCK_SNAPSHOT_NONE: no system_server at %lds — boot may be stuck before system_server\n",
                          (long)gsi18_stuck_delay_secs());
        }
    }
}

/* Backoff / settle sleep that keeps diagnostics serviced:
 * the capture, heartbeat, and stuck logic keep running while
 * the supervisor waits between attempts. */
static void gsi18_poll_sleep(unsigned seconds, int zygote_alive) {
    unsigned total_ms = seconds * 1000;
    unsigned step = gsi18_poll_ms();
    unsigned waited = 0;
    while (waited < total_ms) {
        gsi18_msleep(step);
        waited += step;
        gsi18_service(zygote_alive);
    }
}

/* 6.23: gvld runtime gate (second-opinion design). When guest service
 * isolation patched the guest vold binary, the guest vold must own the
 * "gvld" name in the shared servicemanager before the guest's
 * system_server starts; if the static analysis misjudged and the daemon
 * still registers "vold", the framework half would ask for a "gvld"
 * that nothing owns. The staging script touches
 * /data/gsi_require_gvld in the slot data dir exactly when the patch
 * succeeded. This check runs BEFORE the first fork in main(): poll
 * `service check gvld` for up to ~10s. Absent marker = gate not
 * required (normal boot, zero behavior change). Timeout = return 42;
 * the outer script breaks its restart loop on 42 and aborts the
 * takeover before system_server starts. */
#define GVLD_GATE_EXIT 42
#define GVLD_GATE_MARKER "/data/gsi_require_gvld"

static int gvld_gate_check(void) {
    int i;
    if (access(GVLD_GATE_MARKER, F_OK) != 0) return 0;
    gsi18_sup_log("[gsi_zygote_exec] GVLD_GATE_REQUIRED: polling `service check gvld` (10s)\n");
    for (i = 0; i < 20; i++) {
        FILE *p = popen("service check gvld 2>/dev/null", "r");
        char line[256];
        int found = 0;
        if (p) {
            while (fgets(line, sizeof(line), p)) {
                if (strstr(line, ": found")) { found = 1; break; }
            }
            pclose(p);
        }
        if (found) {
            gsi18_sup_log("[gsi_zygote_exec] GVLD_GATE_OK: gvld owned in servicemanager\n");
            return 0;
        }
        gsi18_msleep(500);
    }
    gsi18_sup_log("[gsi_zygote_exec] GVLD_GATE_FAIL: gvld not owned after 10s — aborting before system_server (exit 42)\n");
    return GVLD_GATE_EXIT;
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

    /* 6.23: gvld runtime gate, before the first fork (see
     * gvld_gate_check). No-op unless the staging script required it. */
    {
        int grc = gvld_gate_check();
        if (grc != 0) return grc;
    }

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
    /* 6.18: supervisor-owned diagnostics start BEFORE the first
     * fork: heartbeat file, tracefs signal tracer, and the
     * continuous logcat capture the supervisor itself watches.
     * All fail-soft; see the helpers above main(). */
    snprintf(gsi18_cap_path, sizeof(gsi18_cap_path), "%s/logcat_continuous.txt", GSI_DIAG_DIR);
    snprintf(gsi18_hb_path, sizeof(gsi18_hb_path), "%s/gsi_heartbeat.log", GSI_DIAG_DIR);
    /* The slot data dir normally exists by staging time; make
     * sure regardless so a missing dir can never silently drop
     * every 6.18 diagnostic file. */
    (void)mkdir(GSI_DIAG_DIR, 0755);
    {
        FILE *hb = fopen(gsi18_hb_path, "a");
        if (hb) {
            fprintf(hb, "HEARTBEAT_START at=%lld\n", (long long)time(NULL));
            fclose(hb);
        }
    }
    snprintf(gsi18_trace_pipe_path, sizeof(gsi18_trace_pipe_path), "%s/gsi_trace_pipe.log", GSI_DIAG_DIR);
    if (gsi18_enable_tracefs()) {
        pid_t tp;
        gsi18_sup_log("[gsi_zygote_exec] TRACEFS_OK: root=%s generate=%d filter=%d sched=%d tracing_on=%d (signal_generate 6/9/11/15)\n",
                      gsi18_trace_root, gsi18_trace_generate_ok, gsi18_trace_filter_ok,
                      gsi18_trace_sched_ok, gsi18_trace_tracing_on_ok);
        tp = gsi18_start_tracepipe();
        if (tp > 0) gsi18_tracepipe_pid = tp;
    } else {
        gsi18_sup_log("[gsi_zygote_exec] TRACEFS_UNAVAILABLE: generate=%d filter=%d sched=%d tracing_on=%d root=%s — signal tracer off, boot continues\n",
                      gsi18_trace_generate_ok, gsi18_trace_filter_ok,
                      gsi18_trace_sched_ok, gsi18_trace_tracing_on_ok,
                      gsi18_trace_root[0] ? gsi18_trace_root : "(none)");
    }
    {
        pid_t cp = gsi18_start_capture();
        if (cp > 0) {
            gsi18_cap_pid = cp;
            gsi18_sup_log("[gsi_zygote_exec] CAPTURE_STARTED: pid=%d path=%s\n",
                          (int)cp, gsi18_cap_path);
        } else {
            gsi18_sup_log("[gsi_zygote_exec] CAPTURE_START_FAILED: path=%s — supervisor will retry, boot continues\n",
                          gsi18_cap_path);
        }
    }
    for (int attempt = 1; attempt <= sup_max_attempts; attempt++) {
        time_t t0 = time(NULL);
        if (attempt == 1) gsi18_t_first = t0;
        /* 6.26: attempt marker in the trace file, written by the
         * supervisor before the fork. The trace file is one
         * append-only file across attempts and runs; without a
         * marker the fresh tail cannot be told from stale lines.
         * O_APPEND write, fail-soft, never touches tracefs. */
        if (gsi18_trace_pipe_path[0]) {
            int mfd = open(gsi18_trace_pipe_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (mfd >= 0) {
                dprintf(mfd, "GSI_TRACE_ATTEMPT attempt=%d wall=%lld suppid=%d\n",
                        attempt, (long long)t0, (int)getpid());
                close(mfd);
            }
        }
        pid_t zpid = fork();
        if (zpid == 0) {
            /* Child: die with the parent, then exec exactly as
             * 6.16 did. The getppid check closes the
             * fork/prctl race: reparented to init means the
             * parent is already gone. */
            (void)prctl(PR_SET_PDEATHSIG, SIGKILL);
            if (getppid() == 1) _exit(127);
            /* 6.19: lmkd/OOM test — pin this child (and the
             * system_server it forks) out of the killer's
             * reach BEFORE execve. If deaths persist at the
             * same timing with adj -1000, lmkd and the kernel
             * OOM killer are both cleared. The read-back is
             * the witness; the parent logs its own read-back
             * in the wait loop. Loud failure, never fatal. */
            {
                int ofd = open("/proc/self/oom_score_adj", O_WRONLY);
                char rb[32];
                int ok = 0;
                rb[0] = '\0';
                if (ofd >= 0) {
                    if (write(ofd, "-1000", 5) == 5) {
                        int rfd = open("/proc/self/oom_score_adj", O_RDONLY);
                        if (rfd >= 0) {
                            ssize_t n = read(rfd, rb, sizeof(rb) - 1);
                            if (n > 0) {
                                size_t L = (size_t)n;
                                rb[L] = '\0';
                                while (L > 0 && (rb[L - 1] == '\n' || rb[L - 1] == ' ')) rb[--L] = '\0';
                                ok = (strcmp(rb, "-1000") == 0);
                            }
                            close(rfd);
                        }
                    }
                    close(ofd);
                }
                {
                    char op[1120];
                    int lfd;
                    snprintf(op, sizeof(op), "%s/oom_adj.log", GSI_DIAG_DIR);
                    lfd = open(op, O_WRONLY | O_CREAT | O_APPEND, 0644);
                    if (lfd >= 0) {
                        dprintf(lfd, "OOM_ADJ_SET attempt=%d pid=%d requested=-1000 readback=%s ok=%d\n",
                                attempt, (int)getpid(), rb[0] ? rb : "(unreadable)", ok);
                        close(lfd);
                    }
                }
            }
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
                if (backoff > 0) gsi18_poll_sleep(backoff, 0);
            }
            continue;
        }
        /* 6.19: GSI_SUP start marker (windowed extract
         * anchors between markers, not timestamps). */
        {
            char mbuf[160];
            snprintf(mbuf, sizeof(mbuf), "ZYGOTE_START n=%d pid=%d at=%lld",
                     attempt, (int)zpid, (long long)time(NULL));
            gsi18_log_marker(mbuf);
        }
        /* 6.19: order-of-death tracking state for this attempt. */
        gsi18_z_pidfd = gsi18_pidfd_open(zpid);
        gsi18_z_exit_bt = -1;
        gsi18_ss_exit_bt = -1;
        gsi18_ss_pid = -1;
        gsi18_ss_pidfd = -1;
        gsi18_ss_done = 0;
        gsi18_zygote_cgroup[0] = '\0';
        gsi18_ss_cgroup[0] = '\0';
        gsi18_read_proc_cgroup(zpid, gsi18_zygote_cgroup, sizeof(gsi18_zygote_cgroup));
        int status = 0;
        pid_t w = -1;
        int wait_failed = 0;
        int oom_logged = 0;
        /* 6.18: poll-wait so diagnostics stay serviced while the
         * zygote runs: capture supervision, heartbeat, and the
         * stuck-boot snapshot all happen in gsi18_service().
         * No waitpid(-1) anywhere: children are tracked by pid,
         * and a stray reap would steal a capture/snapshot
         * child's status (the 6.17 stray reap is deleted for
         * exactly that reason; a pipe-mode writer zombie is
         * reaped when this process exits). */
        for (;;) {
            /* 6.19: per-tick death-order + shield checks, before
             * waitpid so an exit is stamped even if waitpid
             * reaps first. */
            if (!oom_logged) {
                char op[128];
                char rb[64];
                oom_logged = 1;
                snprintf(op, sizeof(op), "/proc/%d/oom_score_adj", (int)zpid);
                if (gsi18_read_small_file(op, rb, sizeof(rb))) {
                    gsi18_sup_log("[gsi_zygote_exec] OOM_ADJ_READBACK attempt=%d pid=%d adj=%s (want -1000)\n",
                                  attempt, (int)zpid, rb);
                } else {
                    gsi18_sup_log("[gsi_zygote_exec] OOM_ADJ_READBACK attempt=%d pid=%d adj=(unreadable)\n",
                                  attempt, (int)zpid);
                }
            }
            if (gsi18_ss_pid < 0 && !gsi18_ss_done) {
                pid_t ss = gsi18_find_system_server_child(zpid);
                if (ss > 0) {
                    gsi18_ss_pid = ss;
                    gsi18_ss_pidfd = gsi18_pidfd_open(ss);
                    gsi18_read_proc_cgroup(ss, gsi18_ss_cgroup, sizeof(gsi18_ss_cgroup));
                    gsi18_sup_log("[gsi_zygote_exec] SS_FOUND attempt=%d system_server=%d cgroup=%s\n",
                                  attempt, (int)ss,
                                  gsi18_ss_cgroup[0] ? gsi18_ss_cgroup : "(none)");
                    /* 6.26: system_server's own OOM shield read-back.
                     * The zygote's adj is witnessed, but the OOM/LMK
                     * verdict for system_server itself was unproven:
                     * the witness lists zygote PIDs only. Read it
                     * at discovery; adj does not move unless the
                     * killer or the framework moves it. */
                    {
                        char op[128];
                        char rb[64];
                        snprintf(op, sizeof(op), "/proc/%d/oom_score_adj", (int)ss);
                        if (gsi18_read_small_file(op, rb, sizeof(rb))) {
                            gsi18_sup_log("[gsi_zygote_exec] SS_OOM_ADJ_READBACK attempt=%d pid=%d adj=%s\n",
                                          attempt, (int)ss, rb);
                        } else {
                            gsi18_sup_log("[gsi_zygote_exec] SS_OOM_ADJ_READBACK attempt=%d pid=%d adj=(unreadable)\n",
                                          attempt, (int)ss);
                        }
                    }
                }
            }
            gsi18_poll_deaths_once();
            w = waitpid(zpid, &status, WNOHANG);
            if (w == zpid) break;
            if (w < 0) {
                if (errno == EINTR) continue;
                wait_failed = 1;
                break;
            }
            gsi18_msleep(gsi18_poll_ms());
            gsi18_service(1);
        }
        /* 6.19: final exit poll (an exit between the last tick
         * and the reap still stamps), then close the pidfds. */
        gsi18_poll_deaths_once();
        if (!wait_failed && w == zpid && gsi18_z_exit_bt < 0) {
            gsi18_z_exit_bt = gsi18_boottime_ms();
        }
        if (gsi18_z_pidfd >= 0) {
            close(gsi18_z_pidfd);
            gsi18_z_pidfd = -1;
        }
        if (gsi18_ss_pidfd >= 0) {
            close(gsi18_ss_pidfd);
            gsi18_ss_pidfd = -1;
        }
        gsi18_sup_log("[gsi_zygote_exec] DEATH_ORDER attempt=%d order=%s zygote_bt_ms=%lld system_server_bt_ms=%lld\n",
                      attempt, gsi18_order_str(), gsi18_z_exit_bt, gsi18_ss_exit_bt);
        time_t t1 = time(NULL);
        long after = (long)(t1 - t0);
        if (after < 0) after = 0;
        if (wait_failed) {
            FILE *lg = fopen("/data/zygote_exec.log", "a");
            if (lg) {
                fprintf(lg, "[gsi_zygote_exec] ZYGOTE_WAIT_FAILED: attempt=%d pid=%d (%s) — boot continues, child reaped by init\n",
                        attempt, (int)zpid, strerror(errno));
                fclose(lg);
            }
            last_status = 1;
            break;
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
        /* 6.19: GSI_SUP exit marker, then tracing off FIRST
         * so the snapshot reads a frozen buffer + drained
         * pipe log. */
        {
            char mbuf[192];
            if (WIFSIGNALED(status)) {
                snprintf(mbuf, sizeof(mbuf), "ZYGOTE_EXIT n=%d sig=%d at=%lld",
                         attempt, WTERMSIG(status), (long long)t1);
            } else if (WIFEXITED(status)) {
                snprintf(mbuf, sizeof(mbuf), "ZYGOTE_EXIT n=%d exit=%d at=%lld",
                         attempt, WEXITSTATUS(status), (long long)t1);
            } else {
                snprintf(mbuf, sizeof(mbuf), "ZYGOTE_EXIT n=%d at=%lld",
                         attempt, (long long)t1);
            }
            gsi18_log_marker(mbuf);
        }
        gsi18_trace_off_first();
        /* 6.18: death snapshot while the evidence is fresh —
         * logcat -d + dmesg + tracefs tail, no shell, 25 s cap.
         * Runs for every death, including signal 9. */
        gsi18_take_death_snapshot(attempt, (long long)t1);
        if (attempt < sup_max_attempts) {
            unsigned backoff = (unsigned)sup_backoff0 << (attempt - 1);
            if (backoff > 0) gsi18_poll_sleep(backoff, 0);
        }
    }
    /* 6.18: stop the supervisor-owned capture at supervisor exit
     * (PR_SET_PDEATHSIG also kills it if this process dies
     * first, so a dead supervisor can never leave a capture
     * writing forever). The capture file stays on disk for the
     * Java bundle, which collects it after the return. */
    if (gsi18_cap_pid > 0) {
        /* 6.19: PID-targeted by construction (tracked pid);
         * log caller + time on every kill. */
        gsi18_sup_log("[gsi_zygote_exec] KILL_PID caller=supervisor_exit pid=%d time=%lld\n",
                      (int)gsi18_cap_pid, (long long)time(NULL));
        (void)kill(gsi18_cap_pid, SIGKILL);
        {
            int dummy = 0;
            (void)waitpid(gsi18_cap_pid, &dummy, WNOHANG);
        }
        gsi18_sup_log("[gsi_zygote_exec] CAPTURE_STOPPED: pid=%d (supervisor exit)\n",
                      (int)gsi18_cap_pid);
        gsi18_cap_pid = -1;
    }
    {
        FILE *hb = fopen(gsi18_hb_path, "a");
        if (hb) {
            fprintf(hb, "HEARTBEAT_END at=%lld\n", (long long)time(NULL));
            fclose(hb);
        }
    }
    /* 6.19: leave tracing off at supervisor exit (no-op if a
     * death already switched it off). */
    gsi18_trace_off_first();
    /* Exit with the last status, shell-style: the outer script
     * sees the same 137 for a SIGKILLed guest it sees today. */
    if (WIFEXITED(last_status)) return WEXITSTATUS(last_status);
    if (WIFSIGNALED(last_status)) return 128 + WTERMSIG(last_status);
    return 1;
}

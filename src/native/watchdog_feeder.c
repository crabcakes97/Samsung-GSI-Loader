/*
 * GSI Loader Samsung 6.2 (P1) — native watchdog feeder, sysfs-enumerating.
 *
 * Canonical watchdog petting for the GSI session, extended from the 6.0
 * held-fd design: the primary node (/dev/watchdog, fallback /dev/watchdog0)
 * is still held open for the whole session and kicked with WDIOC_KEEPALIVE
 * every 5 s, with a magic close (write 'V', then close) on SIGTERM/SIGINT.
 * Supervision is unchanged — switch_to_gsi.sh still runs this binary under
 * its restart-on-exit supervisor with pidfile and liveness checks, and
 * return_to_oneui.sh still kills the supervisor first, then this binary
 * (SIGTERM triggers the magic close below, SIGKILL cleans up any
 * remainder). The binary never touches the watchdog timeout and never
 * stops watchdogd.
 *
 * 6.2 addition — sysfs enumeration (mechanism re-implemented from the
 * OneOS project by fahadalijaved, https://github.com/fahadalijaved/OneOS;
 * this is an original implementation in our own code, not a copy of
 * OneOS's feeder script, and OneOS is credited in the repo CREDITS):
 * on some Exynos phones /dev/watchdog is the HARDWARE watchdog held by
 * init's watchdogd (writes refused EBUSY) while Samsung's "Software
 * Watchdog Timer" is a second node that the held-fd open never sees, so
 * petting only /dev/watchdog leaves the real softdog unfed. Each 2 s
 * cycle this binary therefore enumerates the watchdog class dir and
 * writes "1" to every node the kernel lists as an ACTIVE SOFTWARE
 * watchdog (identity containing "Soft", state "active"), via a
 * transient open-write-close of that node's own /dev entry. Nodes that
 * are inactive or not software are NEVER opened: opening an inactive
 * watchdog would START its timer, and a hardware watchdog must never
 * be started by this feeder. A "V" write to /dev/watchdog is kept for
 * cycles where the primary node is not held (best effort, logged);
 * when the primary node IS held, the SIGTERM magic close is the V
 * write. Every node, its holder (via a proc fd scan), state, timeout, and
 * timeleft is logged on change and in the ~60 s heartbeat, so the log
 * proves which node was actually being fed.
 *
 * Test hooks (unset on the phone; defaults are the production paths):
 *   WATCHDOG_SYSFS_ROOT -- default /sys/class/watchdog
 *   WATCHDOG_DEV_DIR    -- default /dev
 * They exist so the enumeration can be exercised against a fake sysfs
 * tree under emulation; they change nothing when unset.
 *
 * Static build: aarch64-linux-android35-clang -static -O2.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <dirent.h>
#include <ctype.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/watchdog.h>

#define MAX_NODES 16
#define CYCLE_SECS 2
#define IOCTL_SECS 5
#define HEARTBEAT_CYCLES 30

static int g_held_fd = -1;
static char g_held_path[128] = "";
static const char *g_sysfs_root = "/sys/class/watchdog";
static const char *g_dev_dir = "/dev";

/* ---- small helpers ---- */

/* Read a sysfs/proc text file, strip trailing whitespace/newline. 0 ok, -1 fail. */
static int read_trim_file(const char *path, char *buf, size_t len) {
    int fd = open(path, O_RDONLY);
    ssize_t n;
    if (fd < 0) {
        return -1;
    }
    n = read(fd, buf, (ssize_t)(len - 1));
    close(fd);
    if (n < 0) {
        return -1;
    }
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
                     buf[n - 1] == ' ' || buf[n - 1] == '\t')) {
        buf[--n] = '\0';
    }
    return 0;
}

/* Case-insensitive substring search ("soft" in "Software Watchdog"). */
static int ci_contains(const char *hay, const char *needle) {
    size_t nl, hl, i, j;
    if (!hay || !needle) {
        return 0;
    }
    nl = strlen(needle);
    hl = strlen(hay);
    if (nl == 0 || nl > hl) {
        return 0;
    }
    for (i = 0; i + nl <= hl; i++) {
        for (j = 0; j < nl; j++) {
            if (tolower((unsigned char)hay[i + j]) != tolower((unsigned char)needle[j])) {
                break;
            }
        }
        if (j == nl) {
            return 1;
        }
    }
    return 0;
}

static void log_line(const char *msg) {
    printf("[gsi_watchdog_feeder] %s\n", msg);
    fflush(stdout);
}

/* ---- watchdog node enumeration ---- */

struct wdog {
    char name[64];
    char identity[128];
    char state[32];
    char timeout[32];
    char timeleft[32];
    char devpath[160];
    int is_soft;
    int is_active;
    int is_chardev;
};

static void node_devpath(const char *sysfs_name, char *out, size_t outlen) {
    char uevent_path[256];
    char line[192];
    FILE *f;
    /* uevent carries DEVNAME=watchdog0; fall back to the sysfs name. */
    snprintf(uevent_path, sizeof(uevent_path), "%s/%s/uevent", g_sysfs_root, sysfs_name);
    f = fopen(uevent_path, "r");
    if (f != NULL) {
        while (fgets(line, sizeof(line), f) != NULL) {
            if (strncmp(line, "DEVNAME=", 8) == 0) {
                char *v = line + 8;
                size_t l = strlen(v);
                while (l > 0 && (v[l - 1] == '\n' || v[l - 1] == '\r' || v[l - 1] == ' ')) {
                    v[--l] = '\0';
                }
                if (l > 0) {
                    snprintf(out, outlen, "%s/%s", g_dev_dir, v);
                    fclose(f);
                    return;
                }
            }
        }
        fclose(f);
    }
    snprintf(out, outlen, "%s/%s", g_dev_dir, sysfs_name);
}

static int enumerate_nodes(struct wdog *nodes, int max) {
    DIR *d = opendir(g_sysfs_root);
    struct dirent *e;
    int count = 0;
    if (d == NULL) {
        return 0;
    }
    while ((e = readdir(d)) != NULL && count < max) {
        char path[256];
        struct stat st;
        struct wdog *w;
        if (strncmp(e->d_name, "watchdog", 8) != 0) {
            continue;
        }
        w = &nodes[count];
        memset(w, 0, sizeof(*w));
        snprintf(w->name, sizeof(w->name), "%s", e->d_name);
        snprintf(path, sizeof(path), "%s/%s/identity", g_sysfs_root, e->d_name);
        if (read_trim_file(path, w->identity, sizeof(w->identity)) < 0) {
            snprintf(w->identity, sizeof(w->identity), "?");
        }
        snprintf(path, sizeof(path), "%s/%s/state", g_sysfs_root, e->d_name);
        if (read_trim_file(path, w->state, sizeof(w->state)) < 0) {
            snprintf(w->state, sizeof(w->state), "?");
        }
        snprintf(path, sizeof(path), "%s/%s/timeout", g_sysfs_root, e->d_name);
        if (read_trim_file(path, w->timeout, sizeof(w->timeout)) < 0) {
            snprintf(w->timeout, sizeof(w->timeout), "?");
        }
        snprintf(path, sizeof(path), "%s/%s/timeleft", g_sysfs_root, e->d_name);
        if (read_trim_file(path, w->timeleft, sizeof(w->timeleft)) < 0) {
            snprintf(w->timeleft, sizeof(w->timeleft), "?");
        }
        node_devpath(e->d_name, w->devpath, sizeof(w->devpath));
        w->is_soft = ci_contains(w->identity, "soft");
        w->is_active = (strcmp(w->state, "active") == 0);
        w->is_chardev = (stat(w->devpath, &st) == 0 && S_ISCHR(st.st_mode));
        count++;
    }
    closedir(d);
    return count;
}

/* Serialize nodes WITHOUT timeleft (it ticks every second) for change detection. */
static void nodes_snapshot(const struct wdog *nodes, int count, char *out, size_t outlen) {
    size_t used = 0;
    int i;
    out[0] = '\0';
    if (count == 0) {
        snprintf(out, outlen, "(no watchdog nodes)");
        return;
    }
    for (i = 0; i < count; i++) {
        char piece[320];
        snprintf(piece, sizeof(piece), "[%s \"%s\" %s timeout %s dev %s%s]",
                 nodes[i].name, nodes[i].identity, nodes[i].state, nodes[i].timeout,
                 nodes[i].devpath, nodes[i].is_chardev ? "" : " NOT-CHARDEV");
        if (used + strlen(piece) + 1 < outlen) {
            strcpy(out + used, piece);
            used += strlen(piece);
        }
    }
}

/* ---- holder scan: which pids hold a watchdog fd open ---- */

static void scan_holders(char *out, size_t outlen) {
    DIR *procd = opendir("/proc");
    struct dirent *pe;
    size_t used = 0;
    int entries = 0;
    char wdog_prefix[160];
    char soft_prefix[160];
    out[0] = '\0';
    snprintf(wdog_prefix, sizeof(wdog_prefix), "%s/watchdog", g_dev_dir);
    snprintf(soft_prefix, sizeof(soft_prefix), "%s/softdog", g_dev_dir);
    if (procd == NULL) {
        snprintf(out, outlen, "?");
        return;
    }
    while ((pe = readdir(procd)) != NULL && entries < 12) {
        DIR *fdd;
        struct dirent *fe;
        char fdpath[128];
        int holds = 0;
        const char *p = pe->d_name;
        int numeric = 1;
        size_t k;
        if (p[0] == '\0') {
            continue;
        }
        for (k = 0; p[k] != '\0'; k++) {
            if (!isdigit((unsigned char)p[k])) {
                numeric = 0;
                break;
            }
        }
        if (!numeric) {
            continue;
        }
        snprintf(fdpath, sizeof(fdpath), "/proc/%s/fd", p);
        fdd = opendir(fdpath);
        if (fdd == NULL) {
            continue;
        }
        while ((fe = readdir(fdd)) != NULL) {
            char linkpath[160];
            char target[256];
            ssize_t tl;
            snprintf(linkpath, sizeof(linkpath), "%s/%s", fdpath, fe->d_name);
            tl = readlink(linkpath, target, sizeof(target) - 1);
            if (tl < 0) {
                continue;
            }
            target[tl] = '\0';
            if (strncmp(target, wdog_prefix, strlen(wdog_prefix)) == 0 ||
                strcmp(target, soft_prefix) == 0) {
                holds = 1;
                break;
            }
        }
        closedir(fdd);
        if (holds) {
            char commpath[128];
            char comm[64];
            char piece[96];
            snprintf(commpath, sizeof(commpath), "/proc/%s/comm", p);
            if (read_trim_file(commpath, comm, sizeof(comm)) < 0) {
                snprintf(comm, sizeof(comm), "?");
            }
            snprintf(piece, sizeof(piece), " %s:%s", p, comm);
            if (used + strlen(piece) + 1 < outlen) {
                strcpy(out + used, piece);
                used += strlen(piece);
                entries++;
            }
        }
    }
    closedir(procd);
    if (used == 0) {
        snprintf(out, outlen, " (none found)");
    }
}

/* ---- held primary node ---- */

/* Magic close on SIGTERM/SIGINT: disarm, then exit cleanly. */
static void handle_signal(int sig) {
    (void)sig;
    if (g_held_fd >= 0) {
        /* Ignore errors here: we are exiting either way. */
        if (write(g_held_fd, "V", 1) < 0) {
            /* nothing to do on the way out */
        }
        close(g_held_fd);
        g_held_fd = -1;
    }
    _exit(0);
}

static void primary_path(char *out, size_t outlen, const char *leaf) {
    snprintf(out, outlen, "%s/%s", g_dev_dir, leaf);
}

/* Single attempt to hold the primary node. 1 on success, 0 on failure. */
static int try_hold_primary(void) {
    char path[160];
    int fd;
    primary_path(path, sizeof(path), "watchdog");
    fd = open(path, O_WRONLY);
    if (fd < 0) {
        primary_path(path, sizeof(path), "watchdog0");
        fd = open(path, O_WRONLY);
    }
    if (fd < 0) {
        return 0;
    }
    g_held_fd = fd;
    snprintf(g_held_path, sizeof(g_held_path), "%s", path);
    return 1;
}

/* ---- one 2 s cycle: kick enumerated nodes + best-effort V to primary ---- */

static void kick_cycle(char *results, size_t results_len) {
    struct wdog nodes[MAX_NODES];
    int count = enumerate_nodes(nodes, MAX_NODES);
    int i;
    size_t used = 0;
    results[0] = '\0';
    if (count == 0) {
        snprintf(results, results_len, "no watchdog nodes under %s; ", g_sysfs_root);
        used = strlen(results);
    }
    for (i = 0; i < count; i++) {
        char piece[192];
        if (!nodes[i].is_active || !nodes[i].is_soft) {
            snprintf(piece, sizeof(piece), "%s:skipped(%s%s) ",
                     nodes[i].name, nodes[i].is_soft ? "software" : "not-software",
                     nodes[i].is_active ? ",active" : ",inactive");
        } else if (!nodes[i].is_chardev) {
            snprintf(piece, sizeof(piece), "%s:skipped(no char dev %s) ",
                     nodes[i].name, nodes[i].devpath);
        } else if (g_held_fd >= 0 && strcmp(nodes[i].devpath, g_held_path) == 0) {
            snprintf(piece, sizeof(piece), "%s:held-fd ", nodes[i].name);
        } else {
            int fd = open(nodes[i].devpath, O_WRONLY);
            if (fd < 0) {
                snprintf(piece, sizeof(piece), "%s:refused ", nodes[i].name);
            } else {
                if (write(fd, "1", 1) < 0) {
                    snprintf(piece, sizeof(piece), "%s:write-failed ", nodes[i].name);
                } else {
                    snprintf(piece, sizeof(piece), "%s:kicked ", nodes[i].name);
                }
                close(fd);
            }
        }
        if (used + strlen(piece) + 1 < results_len) {
            strcpy(results + used, piece);
            used += strlen(piece);
        }
    }
    /* "V" write to the primary node when it is NOT held (best effort;
       when held, the SIGTERM magic close is the V write). */
    if (g_held_fd < 0) {
        char path[160];
        int fd;
        primary_path(path, sizeof(path), "watchdog");
        fd = open(path, O_WRONLY);
        if (fd >= 0) {
            if (write(fd, "V", 1) < 0) {
                snprintf(results + used, results_len - used, "V:write-failed");
            } else {
                snprintf(results + used, results_len - used, "V:written");
            }
            close(fd);
        } else {
            snprintf(results + used, results_len - used, "V:refused");
        }
    }
}

int main(int argc, char **argv) {
    const char *env;
    struct wdog nodes[MAX_NODES];
    char snap[2048];
    char prev_snap[2048] = "";
    char results[1024];
    char prev_results[1024] = "";
    char holders[512];
    char msg[2600];
    int cycle = 0;
    time_t last_ioctl = 0;
    int i;
    (void)argc;
    (void)argv;

    env = getenv("WATCHDOG_SYSFS_ROOT");
    if (env != NULL && env[0] != '\0') {
        g_sysfs_root = env;
    }
    env = getenv("WATCHDOG_DEV_DIR");
    if (env != NULL && env[0] != '\0') {
        g_dev_dir = env;
    }

    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);

    log_line("starting (6.2 P1 sysfs-enumerating feeder; held-fd primary + active-software node kicks every 2s)");

    /* Startup burst: hold the primary node promptly (~5 s), like 6.0. */
    for (i = 0; i < 25; i++) {
        if (try_hold_primary()) {
            break;
        }
        usleep(200000); /* 200 ms */
    }
    if (g_held_fd >= 0) {
        snprintf(msg, sizeof(msg), "holding primary node %s on fd %d (WDIOC_KEEPALIVE every 5s)", g_held_path, g_held_fd);
        log_line(msg);
    } else {
        snprintf(msg, sizeof(msg), "WARNING: cannot hold %s/watchdog or %s/watchdog0 — will keep retrying each cycle; enumerated kicks below are the coverage", g_dev_dir, g_dev_dir);
        log_line(msg);
    }

    for (;;) {
        int count;
        cycle++;

        if (g_held_fd < 0) {
            if (try_hold_primary()) {
                snprintf(msg, sizeof(msg), "holding primary node %s on fd %d (retry succeeded)", g_held_path, g_held_fd);
                log_line(msg);
            }
        }

        /* Held-fd keepalive every ~5 s (first cycle immediately). */
        if (g_held_fd >= 0) {
            time_t now = time(NULL);
            if (last_ioctl == 0 || now - last_ioctl >= IOCTL_SECS) {
                int dummy = 0;
                if (ioctl(g_held_fd, WDIOC_KEEPALIVE, &dummy) < 0) {
                    /* Fallback: a plain write is also a ping on standard drivers. */
                    if (write(g_held_fd, "\0", 1) < 0) {
                        /* Keep looping: the supervisor owns restart policy. */
                    }
                }
                last_ioctl = now;
            }
        }

        kick_cycle(results, sizeof(results));

        /* Node dump: on change, and every ~60 s as a heartbeat. */
        count = enumerate_nodes(nodes, MAX_NODES);
        nodes_snapshot(nodes, count, snap, sizeof(snap));
        if (strcmp(snap, prev_snap) != 0 || (cycle % HEARTBEAT_CYCLES) == 0) {
            int j;
            scan_holders(holders, sizeof(holders));
            snprintf(msg, sizeof(msg), "nodes (cycle %d): %s ; held by:%s", cycle, snap, holders);
            log_line(msg);
            for (j = 0; j < count; j++) {
                snprintf(msg, sizeof(msg), "  node %s identity=\"%s\" state=%s timeout=%s timeleft=%s dev=%s",
                         nodes[j].name, nodes[j].identity, nodes[j].state,
                         nodes[j].timeout, nodes[j].timeleft, nodes[j].devpath);
                log_line(msg);
            }
            snprintf(prev_snap, sizeof(prev_snap), "%s", snap);
        }
        /* Kick results: log on change, and with the heartbeat. */
        if (strcmp(results, prev_results) != 0 || (cycle % HEARTBEAT_CYCLES) == 0) {
            snprintf(msg, sizeof(msg), "kick cycle %d: %s", cycle, results);
            log_line(msg);
            snprintf(prev_results, sizeof(prev_results), "%s", results);
        }

        sleep(CYCLE_SECS);
    }

    return 0; /* unreachable */
}

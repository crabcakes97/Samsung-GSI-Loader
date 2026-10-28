#!/system/bin/sh
# Boot watchdog (GSI Loader Samsung 5.9.11).
#
# Problem it solves: if the guest boots far enough to take over the
# screen but its system_server never reaches the home screen (patched
# -jar mismatch, a wedged HAL wait, a first-boot scan that never
# finishes), the phone used to sit on the boot screen forever until
# the user force-restarted it. This script bounds that failure: if
# the guest has not reached home within a generous window, it runs
# the EXISTING, tested return path (return_to_oneui.sh) so the phone
# comes back to One UI on its own.
#
# Safety:
#  - It only ever RUNS return_to_oneui.sh. It deletes nothing, wipes
#    nothing, and never touches host /data or host system. A
#    watchdog-triggered return PRESERVES the guest (system.raw and
#    guest data stay), so the user can retry the boot afterwards.
#  - It exits on its own when the guest reaches home, when a return
#    already ran (the guest rootfs is unmounted — 5.9.13: mount
#    state, NOT the .guest_running marker, which a force-restart
#    leaves stale), or right after it triggers a return.
#    return_to_oneui.sh also kills it (pkill -f boot_watchdog.sh) so
#    a manual return never leaves a stray watchdog behind.
#  - On timeout it first captures a bounded boot-diagnostics bundle
#    (boot_diagnostics.sh, 5.9.13: takeover tails, mounts, logcat
#    crash lines, dmesg erofs lines) while the guest is still up,
#    so a failed boot — especially an EROFS crash — is diagnosable
#    from the app log on next launch instead of a bare timeout.
#  - Window is 600s (10 min) by default: first boot after a fresh
#    install runs dexopt + a package scan and is legitimately slow
#    (minutes), so a short window would false-positive on exactly
#    the boots that need patience. A 10-minute bound still catches
#    a genuinely stuck guest long before a user gives up and
#    force-restarts.
#
# How "home reached" is detected: the UI Activator (started by
# switch_to_gsi.sh alongside this watchdog) appends "Home
# activated!" to /data/local/tmp/ui_activator.log once it has
# dismissed the boot animation and fired the HOME intent. That log
# is truncated fresh at every takeover launch, so a match found
# here belongs to THIS boot, not a previous one. 5.9.16 fallback:
# if the string never arrives, home is also accepted when a guest
# system_server rooted under this slot's rootfs reports mStatusBar
# via nsenter dumpsys window (see home_reached_fallback below) —
# so a dead Activator cannot false-time-out a healthy guest.
#
# Usage: boot_watchdog.sh <slotDir>
# Test overrides (VM harness only; never set on the phone):
#   BOOT_WATCHDOG_INTERVAL — seconds between checks (default 15)
#   BOOT_WATCHDOG_ROUNDS   — checks before timeout (default 40)
#   BOOT_WATCHDOG_RETURN   — return script path override (default:
#                            STAGE_DIR/return_to_oneui.sh, falling
#                            back to <slotDir>/return_to_oneui.sh)
#   BOOT_WATCHDOG_LOG      — activator log path override
#   BOOT_WATCHDOG_TMPLOG   — watchdog log path override
STAGE_DIR="/data/local/tmp/lineage_stage"
SLOT_DIR="${1:-$STAGE_DIR}"
INTERVAL="${BOOT_WATCHDOG_INTERVAL:-15}"
ROUNDS="${BOOT_WATCHDOG_ROUNDS:-40}"
ACTIVATOR_LOG="${BOOT_WATCHDOG_LOG:-/data/local/tmp/ui_activator.log}"
WATCH_LOG="${BOOT_WATCHDOG_TMPLOG:-/data/local/tmp/boot_watchdog.log}"
MARKER="$SLOT_DIR/boot_watchdog_timeout"
RETURN_SCRIPT="${BOOT_WATCHDOG_RETURN:-}"

# 5.9.16: fallback home detection. The primary signal stays the
# UI Activator's "Home activated!" string (see below), but if the
# Activator dies, its log path changes, or the guest reaches home by
# another path, the string never arrives and the watchdog would
# false-time-out a healthy guest at 10 min. The fallback is the same
# evidence the UI Activator itself uses, checked inside this script
# (switch_to_gsi.sh is owned by another workstream and is not
# touched): a guest system_server process rooted under this slot's
# rootfs, AND a guest WindowManager state showing mStatusBar via
# dumpsys window run inside that process's mount namespace with
# nsenter (a host-namespace dumpsys would query the host window
# manager, not the guest's, so it is never used here). Both halves
# must hold; either half failing means "not proven home".
BB="$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)"
[ -x "$BB" ] || BB=""
guest_system_server_pid() {
    for _p in /proc/[0-9]*; do
        [ -d "$_p" ] || continue
        _root="$(readlink "$_p/root" 2>/dev/null)"
        if [ "$_root" = "$SLOT_DIR/rootfs" ]; then
            if tr '\0' ' ' < "$_p/cmdline" 2>/dev/null | grep -q "system_server"; then
                basename "$_p"; return 0
            fi
        fi
    done
    return 1
}
home_reached_fallback() {
    _pid="$(guest_system_server_pid)" || return 1
    if command -v nsenter >/dev/null 2>&1; then
        nsenter -t "$_pid" -m /system/bin/dumpsys window 2>/dev/null | grep -q 'mStatusBar'
    elif [ -n "$BB" ]; then
        "$BB" nsenter -t "$_pid" -m /system/bin/dumpsys window 2>/dev/null | grep -q 'mStatusBar'
    else
        return 1
    fi
}

echo "BOOT_WATCHDOG_ARMED: slot=$SLOT_DIR window=$((INTERVAL * ROUNDS))s" >> "$WATCH_LOG" 2>/dev/null
echo "BOOT_WATCHDOG_ARMED: slot=$SLOT_DIR window=$((INTERVAL * ROUNDS))s" >> "$SLOT_DIR/boot_watchdog.log" 2>/dev/null

i=0
while [ "$i" -lt "$ROUNDS" ]; do
    sleep "$INTERVAL"
    i=$((i + 1))
    # Guest reached home? UI Activator says so explicitly.
    if grep -q "Home activated!" "$ACTIVATOR_LOG" 2>/dev/null; then
        echo "BOOT_WATCHDOG_OK: guest reached home" >> "$WATCH_LOG" 2>/dev/null
        echo "BOOT_WATCHDOG_OK: guest reached home" >> "$SLOT_DIR/boot_watchdog.log" 2>/dev/null
        exit 0
    fi
    # Return already ran (guest rootfs unmounted by return_to_oneui.sh)?
    # Then there is nothing left to watch — exit quietly.
    # 5.9.13: mount state, NOT the .guest_running marker. The marker
    # is removed only by the return script, so a force-restart leaves
    # it stale; a marker-based check would misread a stale marker as
    # "still running" forever. The rootfs mount exists for the whole
    # live guest session (master_prepare.sh mounts it in the host
    # namespace before the takeover daemon launches) and is gone
    # after any return, so it is the reliable signal. (A reboot kills
    # this script too, so no stale-watchdog case arises from it.)
    if ! mount | grep -q "$SLOT_DIR/rootfs " 2>/dev/null; then
        echo "BOOT_WATCHDOG_DONE: guest rootfs unmounted (returned already)" >> "$WATCH_LOG" 2>/dev/null
        exit 0
    fi
    # 5.9.16 fallback: string absent, but guest system_server is up
    # and its WindowManager shows mStatusBar — that IS home, even
    # if the UI Activator never wrote its line. Logged distinctly
    # (BOOT_WATCHDOG_OK_FALLBACK) so on-device runs can tell which
    # signal fired; the string path above stays primary and first.
    if home_reached_fallback; then
        echo "BOOT_WATCHDOG_OK_FALLBACK: guest reached home (system_server + mStatusBar; UI Activator string absent)" >> "$WATCH_LOG" 2>/dev/null
        echo "BOOT_WATCHDOG_OK_FALLBACK: guest reached home (system_server + mStatusBar; UI Activator string absent)" >> "$SLOT_DIR/boot_watchdog.log" 2>/dev/null
        exit 0
    fi
done

# One last fallback check before declaring a timeout: the final
# round's fallback ran up to INTERVAL seconds ago, and a guest that
# reached home in that gap must not be returned.
if home_reached_fallback; then
    echo "BOOT_WATCHDOG_OK_FALLBACK: guest reached home (system_server + mStatusBar; UI Activator string absent)" >> "$WATCH_LOG" 2>/dev/null
    echo "BOOT_WATCHDOG_OK_FALLBACK: guest reached home (system_server + mStatusBar; UI Activator string absent)" >> "$SLOT_DIR/boot_watchdog.log" 2>/dev/null
    exit 0
fi

# Timeout: still mounted, home never activated.
echo "BOOT_WATCHDOG_TIMEOUT: guest did not reach home within $((INTERVAL * ROUNDS))s — returning to One UI" >> "$WATCH_LOG" 2>/dev/null
echo "BOOT_WATCHDOG_TIMEOUT: guest did not reach home within $((INTERVAL * ROUNDS))s — returning to One UI" >> "$SLOT_DIR/boot_watchdog.log" 2>/dev/null
# 5.9.13: capture diagnostics BEFORE the return tears the guest down
# (mounts, takeover tails, logcat crash lines, dmesg erofs lines).
# Failure to capture must never block the return itself.
if [ -f "$SLOT_DIR/boot_diagnostics.sh" ]; then
    /system/bin/sh "$SLOT_DIR/boot_diagnostics.sh" "$SLOT_DIR" >> "$WATCH_LOG" 2>&1 || true
elif [ -f "$STAGE_DIR/boot_diagnostics.sh" ]; then
    /system/bin/sh "$STAGE_DIR/boot_diagnostics.sh" "$SLOT_DIR" >> "$WATCH_LOG" 2>&1 || true
else
    echo "BOOT_WATCHDOG_NOTE: boot_diagnostics.sh missing — no diagnostics bundle captured" >> "$WATCH_LOG" 2>/dev/null
fi
touch "$MARKER" 2>/dev/null || true

if [ -z "$RETURN_SCRIPT" ]; then
    if [ -f "$STAGE_DIR/return_to_oneui.sh" ]; then
        RETURN_SCRIPT="$STAGE_DIR/return_to_oneui.sh"
    elif [ -f "$SLOT_DIR/return_to_oneui.sh" ]; then
        RETURN_SCRIPT="$SLOT_DIR/return_to_oneui.sh"
    fi
fi
if [ -n "$RETURN_SCRIPT" ]; then
    /system/bin/sh "$RETURN_SCRIPT" >> "$WATCH_LOG" 2>&1 || true
else
    echo "BOOT_WATCHDOG_FAIL: no return script found — phone left as-is (reboot returns to One UI)" >> "$WATCH_LOG" 2>/dev/null
fi
exit 0

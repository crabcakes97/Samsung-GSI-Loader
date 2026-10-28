#!/system/bin/sh
# Return to One UI / Safe State Restoration (5.9.5 hardened)
# Usage: return_to_oneui.sh [--reboot]
#   --reboot: after best-effort return (even if partial), reboot the
#   device. This is the user's panic option; Java confirms before
#   calling with this flag — this script just implements it.
# Verification: each step below records its failures in FAILED_STEPS.
# The script prints "RETURN_OK" only if every verified step passed,
# otherwise "RETURN_PARTIAL <failed steps>".
# Guest-process killing: name kills below are kept for the guest's own
# watchdog/activator processes, but host-shared names (system_server,
# surfaceflinger, vold, wificond, zygote64) are killed ONLY when a
# guest rootfs is actually mounted (see kill_guest_procs), so a return
# run on stock One UI cannot kill the host's real daemons. imsd is
# NEVER killed here: it owns the modem's IMS registration and must
# survive the return (see switch_to_gsi.sh IMS gate).
BACKUP_DIR="/data/local/tmp/lineage_backups"
STAGE_ROOT="/data/local/tmp/lineage_stage"
REBOOT_AFTER=0
for _arg in "$@"; do
    case "$_arg" in
        --reboot) REBOOT_AFTER=1 ;;
    esac
done
FAILED_STEPS=""
add_failed() {
    case " $FAILED_STEPS " in
        *" $1 "*) ;;
        *) FAILED_STEPS="$FAILED_STEPS $1" ;;
    esac
    FAILED_STEPS="$(printf '%s' "$FAILED_STEPS" | sed 's/^ //')"
}
# kill_guest_procs: kill -9 any process whose root is under a lineage
# rootfs (Default or any slot), plus — only if such a rootfs is mounted
# — the guest daemons by name. Never kills PID 1 or this script itself.
kill_guest_procs() {
    _guest_mounted=0
    if mount 2>/dev/null | grep -q "lineage_stage.*rootfs"; then
        _guest_mounted=1
    fi
    for _d in /proc/[0-9]*; do
        [ -d "$_d" ] || continue
        _pid="${_d##*/}"
        [ "$_pid" = "$$" ] && continue
        [ "$_pid" = "1" ] && continue
        _rl="$(readlink "$_d/root" 2>/dev/null)"
        case "$_rl" in
            "$STAGE_ROOT"/rootfs|"$STAGE_ROOT"/rootfs/*|"$STAGE_ROOT"/slots/*/rootfs|"$STAGE_ROOT"/slots/*/rootfs/*)
                kill -9 "$_pid" 2>/dev/null || true
                continue
                ;;
        esac
        if [ -f "$_d/cmdline" ]; then
            _cl="$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)"
            case "$_cl" in
                *"$STAGE_ROOT"*/rootfs*) kill -9 "$_pid" 2>/dev/null || true ;;
            esac
        fi
    done
    if [ "$_guest_mounted" = "1" ]; then
        pkill -9 -f "system_server" 2>/dev/null || true
        pkill -9 -x zygote64 2>/dev/null || true
        kill -9 $(pidof surfaceflinger) 2>/dev/null || true
        kill -9 $(pidof vold) 2>/dev/null || true
        kill -9 $(pidof wificond) 2>/dev/null || true
        kill -9 $(pidof bootanimation) 2>/dev/null || true
    fi
}

echo "=== [1/5] Terminating Container Supervision & Zygote ==="
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
pkill -9 -f "kill -STOP" 2>/dev/null || true
pkill -9 -f "ui_activator" 2>/dev/null || true
pkill -9 -f "zygote_exec" 2>/dev/null || true
# Stop the adb watchdog started by switch_to_gsi.sh before One UI's own
# system_server comes back, so it cannot fight init over sys.usb.config.
pkill -9 -f "adb_watchdog.sh" 2>/dev/null || true
pkill -9 -f "ims_watchdog.sh" 2>/dev/null || true
# 5.9.11: stop the boot watchdog too, so a manual return never leaves
# a stray watchdog that could later fire a return of its own.
pkill -9 -f "boot_watchdog.sh" 2>/dev/null || true
# 5.9.5-SCRIPTS: guest processes (zygote, system_server, surfaceflinger,
# vold, wificond, and any process rooted in a guest rootfs) via
# kill_guest_procs above — gated on a mounted guest rootfs for the
# shared-name daemons, so host daemons are not killed on stock One UI.
# No guest-brand process kills: a brand-specific pattern would miss
# every other GSI anyway. imsd is deliberately NOT killed here.
kill_guest_procs 2>/dev/null || true

# Put the host's own /data trees back FIRST: master_prepare.sh bridges the
# staged app trees (installd/artd write there), and the One UI launcher restore
# below must read the host's real /data/user/0, not the guest's.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    umount "/data/$d" 2>/dev/null || true
done

echo "=== [2/5] Restoring One UI Home Screen Layout & Permissions ==="
LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_DATA="/data/user/0/$LAUNCHER_PKG"
LAUNCHER_UID=$(stat -c %u "$LAUNCHER_DATA" 2>/dev/null || echo 10160)
LAUNCHER_GID=$(stat -c %g "$LAUNCHER_DATA" 2>/dev/null || echo 10160)

if [ -d "$BACKUP_DIR" ] && [ -d "$LAUNCHER_DATA/databases" ]; then
    cp -a "$BACKUP_DIR"/* "$LAUNCHER_DATA/databases/" 2>/dev/null || true
    chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 771 "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 660 "$LAUNCHER_DATA/databases"/* 2>/dev/null || true
    echo "One UI Home screen database restored with UID $LAUNCHER_UID:$LAUNCHER_GID"
fi

echo "=== [3/5] Unmounting Container Overlays ==="
# Slot-aware (5.9.3): unmount the Default rootfs AND any slot rootfs
# (slots/<name>/rootfs) that is mounted. The mount-point list is
# recomputed each pass; the loop is bounded so it can never hang.
n=0
while [ $n -lt 50 ]; do
    MPTS=$(mount 2>/dev/null | grep -F 'lineage_stage' | grep -F 'rootfs' | sed -e 's/^.* on //; s/ type .*//' | sort -u)
    [ -n "$MPTS" ] || break
    for m in $MPTS; do
        umount -l "$m"/* 2>/dev/null || true
        umount -l "$m"/apex/* 2>/dev/null || true
        umount -l "$m" 2>/dev/null || true
    done
    n=$((n+1))
    sleep 0.1
done
BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
if [ -x "$BB" ]; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
fi

echo "=== [4/5] Restoring Storage Mounts ==="
umount -l /storage/emulated 2>/dev/null || true
umount -l /mnt/user/0/emulated 2>/dev/null || true
mkdir -p /storage/emulated/0
mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true

echo "=== [5/5] Starting One UI Display & Host Services ==="
setprop ctl.start surfaceflinger
setprop ctl.start zygote
setprop ctl.start audioserver
setprop ctl.start cameraserver
# switch_to_gsi.sh stops the host media codec stack (its IMediaCodecList AIDL
# hash does not match the GSI's, which spins the guest's MediaCodecList); bring it
# back for One UI.
for svc in media media.extractor media.metrics wificond; do
    setprop ctl.start $svc 2>/dev/null || true
done
am force-stop com.sec.android.app.launcher 2>/dev/null || true
am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null || true

# switch_to_gsi.sh drops SELinux to permissive for the takeover; restore it.
setenforce 1 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
# 5.9.5-SCRIPTS-START: verify EACH step, clear the guest marker, report.
# A missing Android tool (setprop/getprop/getenforce on a non-Android
# host) counts as a failed/unverified step, not a silent pass.
rm -f "$STAGE_ROOT/.guest_running" 2>/dev/null || true
for _slotdir in "$STAGE_ROOT"/slots/*; do
    [ -d "$_slotdir" ] && rm -f "$_slotdir/.guest_running" 2>/dev/null || true
done
if mount 2>/dev/null | grep -q "lineage_stage.*rootfs"; then
    add_failed unmount
fi
if command -v getprop >/dev/null 2>&1; then
    [ "$(getprop init.svc.zygote 2>/dev/null)" = "running" ] || add_failed zygote
else
    add_failed zygote
fi
if command -v getenforce >/dev/null 2>&1; then
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || add_failed setenforce
else
    add_failed setenforce
fi
if [ -z "$FAILED_STEPS" ]; then
    echo "RETURN_OK"
else
    echo "RETURN_PARTIAL $FAILED_STEPS"
fi
if [ "$REBOOT_AFTER" = "1" ]; then
    echo "RETURN: --reboot requested, rebooting after best-effort return"
    if command -v reboot >/dev/null 2>&1; then
        reboot 2>/dev/null || true
    else
        setprop sys.powerctl reboot 2>/dev/null || true
    fi
fi
# 5.9.5-SCRIPTS-END
echo "One UI restored successfully."
[ -z "$FAILED_STEPS" ] || exit 1
exit 0

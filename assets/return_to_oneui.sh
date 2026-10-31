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
# 5.9.16: stop the watchdog feeder + keepalives (FIXES THE LEAK).
# The pre-5.9.16 feeder leaked after return because nothing killed it.
# Kill by EXACT script names, and log each kill so a leaked feeder is
# visible in the return log instead of silently petting the watchdog
# in One UI and masking whether host watchdogd is alive.
# Explicitly NOT killed here: host watchdogd itself. No pkill on
# "watchdogd", no ctl.stop watchdogd — the keepalive pattern below
# (host_watchdogd_keepalive.sh) does not match the watchdogd binary,
# and the feeder patterns do not either. Host protection stays up.
_FEEDER_PID_BEFORE="$(cat /data/local/tmp/gsi_watchdog_feeder.pid 2>/dev/null || echo none)"
if pkill -9 -f "gsi_watchdog_supervisor.sh" 2>/dev/null; then
    echo "WATCHDOG_FEEDER_KILL: supervisor killed (pidfile was $_FEEDER_PID_BEFORE)"
else
    echo "WATCHDOG_FEEDER_KILL: supervisor not found (already dead or never started; pidfile was $_FEEDER_PID_BEFORE)"
fi
# 6.0 (P1): stop the native ioctl feeder cleanly. The supervisor is
# already dead above, so it cannot restart the binary. SIGTERM
# triggers the binary's magic close (write 'V' + close = driver
# disarms); SIGKILL cleans up any remainder after a short wait.
# The binary's cmdline is exactly /data/local/tmp/watchdog_feeder,
# which matches neither the supervisor/worker script patterns nor
# the legacy /dev/watchdog pattern below, so it needs this block.
if pkill -TERM -f "/data/local/tmp/watchdog_feeder" 2>/dev/null; then
    echo "WATCHDOG_FEEDER_KILL: native feeder SIGTERM sent (magic close)"
    sleep 1
else
    echo "WATCHDOG_FEEDER_KILL: native feeder not found (shell worker only, or never started)"
fi
if pkill -KILL -f "/data/local/tmp/watchdog_feeder" 2>/dev/null; then
    echo "WATCHDOG_FEEDER_KILL: native feeder remainder SIGKILLed"
fi
rm -f /data/local/tmp/watchdog_feeder 2>/dev/null || true
if pkill -9 -f "gsi_watchdog_feeder.sh" 2>/dev/null; then
    echo "WATCHDOG_FEEDER_KILL: worker killed"
else
    echo "WATCHDOG_FEEDER_KILL: worker not found"
fi
if pkill -9 -f "host_watchdogd_keepalive.sh" 2>/dev/null; then
    echo "HOST_WATCHDOGD_KEEPALIVE_KILL: keepalive daemon killed (watchdogd itself NOT stopped)"
else
    echo "HOST_WATCHDOGD_KEEPALIVE_KILL: keepalive daemon not found (watchdogd itself untouched)"
fi
if pkill -9 -f "gsi_guest_kicker_supervisor.sh" 2>/dev/null; then
    echo "GUEST_KICKER_KILL: guest kicker supervisor killed"
else
    echo "GUEST_KICKER_KILL: guest kicker supervisor not found"
fi
if pkill -9 -f "gsi_guest_kicker.sh" 2>/dev/null; then
    echo "GUEST_KICKER_KILL: guest kicker worker killed"
else
    echo "GUEST_KICKER_KILL: guest kicker worker not found"
fi
if pkill -9 -f "/dev/watchdog" 2>/dev/null; then
    echo "WATCHDOG_FEEDER_KILL: legacy pre-5.9.16 feeder (cmdline /dev/watchdog loop) killed"
else
    echo "WATCHDOG_FEEDER_KILL: no legacy feeder found"
fi
rm -f /data/local/tmp/gsi_watchdog_feeder.pid /data/local/tmp/host_watchdogd_keepalive.pid 2>/dev/null || true
if ps -ef 2>/dev/null | grep -v grep | grep -q "gsi_watchdog_supervisor.sh"; then
    echo "WATCHDOG_FEEDER_KILL: WARNING supervisor still listed after kill — check ps"
else
    echo "WATCHDOG_FEEDER_KILL: confirmed no supervisor process remains"
fi
# 5.9.18: restore the kernel watchdog timeout neutralized at guest
# launch (session-scoped only). The helper script was written by
# switch_to_gsi.sh into /data/local/tmp/ at session start; if it is
# missing (session started by an older build, or the file was deleted),
# fall back to a minimal inline restore from the orig file. If neither
# exists, the timeout was never neutralized — or a reboot already
# reset it to the driver default — and there is nothing to restore.
# The helper keeps the orig file on restore failure so a later return
# can retry; a reboot resets the timeout regardless.
if [ -f /data/local/tmp/gsi_watchdog_timeout.sh ]; then
    /system/bin/sh /data/local/tmp/gsi_watchdog_timeout.sh restore || echo "WATCHDOG_TIMEOUT_RESTORE_WARNING: restore verb reported a failure (see lines above; a reboot resets the timeout to the driver default)"
elif [ -f /data/local/tmp/gsi_watchdog_timeout.orig ]; then
    _need=0; _done=0
    while IFS='|' read -r _rn _ro || [ -n "$_rn" ]; do
        [ -n "$_rn" ] || continue
        [ -n "$_ro" ] || continue
        _need=$((_need + 1))
        if [ -f "/sys/class/watchdog/$_rn/timeout" ] && echo "$_ro" > "/sys/class/watchdog/$_rn/timeout" 2>/dev/null; then
            echo "WATCHDOG_TIMEOUT_RESTORED: node=$_rn timeout=$_ro (inline fallback; helper script missing)"
            _done=$((_done + 1))
        fi
    done < /data/local/tmp/gsi_watchdog_timeout.orig
    if [ "$_need" -gt 0 ] && [ "$_done" -eq "$_need" ]; then
        rm -f /data/local/tmp/gsi_watchdog_timeout.orig 2>/dev/null || true
    elif [ "$_done" -eq 0 ]; then
        echo "WATCHDOG_TIMEOUT_RESTORE_WARNING: inline fallback could not restore any timeout (a reboot resets the timeout to the driver default)"
    else
        echo "WATCHDOG_TIMEOUT_RESTORE_WARNING: inline fallback restored $_done of $_need timeouts (orig file kept for retry; a reboot resets the timeout to the driver default)"
    fi
else
    echo "WATCHDOG_TIMEOUT_RESTORE_SKIPPED: no helper script and no orig file (timeout was never neutralized this boot)"
fi
# 6.2 (P3): restore One UI's persist.* props snapshotted at takeover
# (mechanism re-implemented from OneOS/fahadalijaved; this restore is
# our own code). Runs BEFORE the host zygote restarts in [5/5] below,
# so One UI boots with its own values. The snapshot file survives a
# reboot (/data/local/tmp persists), so a return after a hard reset
# restores too; a return that runs twice is harmless (the file is
# removed after a successful restore, and a missing file just logs).
# The resetprop spelling proven at switch time is read back from the
# spelling file so a persisted (-p) session value is fixed in the
# persistent store too, not only live. persist.vendor.softdog set by
# a session is deleted when it was not in the snapshot; every other
# snapshotted value is written back. (Unlike OneOS's restore, props
# the guest or host added mid-session are NOT deleted wholesale —
# only the session's own softdog prop is removed — so no host state
# is ever nuked by a delete-all.)
# If resetprop is missing here, nothing is restored — logged loudly,
# and the next switch's stale-snapshot recovery retries it.
if [ -f /data/local/tmp/gsi_persist_snapshot ]; then
    _PR_RP=$(which resetprop 2>/dev/null || echo "/data/adb/ksu/bin/resetprop")
    [ -x "$_PR_RP" ] || _PR_RP=$(find /data/adb /system -name resetprop 2>/dev/null | head -n 1)
    _SP_SET=""; _SP_DEL="--delete"; _SP_DELP=""
    if [ -f /data/local/tmp/gsi_persist_spelling ]; then
        _SP_LINE="$(head -n 1 /data/local/tmp/gsi_persist_spelling 2>/dev/null)"
        _SP_SET="${_SP_LINE%%|*}"; _SP_REST="${_SP_LINE#*|}"
        _SP_DEL="${_SP_REST%%|*}"; _SP_DELP="${_SP_REST#*|}"
    fi
    if [ -n "$_PR_RP" ] && [ -x "$_PR_RP" ]; then
        _pr_restored=0; _pr_failed=0
        while IFS= read -r _pr_line || [ -n "$_pr_line" ]; do
            case "$_pr_line" in
                ''|'#'*) continue ;;
            esac
            _pr_name="${_pr_line%%=*}"; _pr_val="${_pr_line#*=}"
            [ -n "$_pr_name" ] || continue
            if [ -n "$_SP_SET" ]; then
                "$_PR_RP" $_SP_SET "$_pr_name" "$_pr_val" 2>/dev/null || { _pr_failed=$((_pr_failed + 1)); continue; }
            else
                "$_PR_RP" "$_pr_name" "$_pr_val" 2>/dev/null || { _pr_failed=$((_pr_failed + 1)); continue; }
            fi
            _pr_restored=$((_pr_restored + 1))
        done < /data/local/tmp/gsi_persist_snapshot
        echo "PERSIST_RESTORE: restored $_pr_restored props from gsi_persist_snapshot, $_pr_failed failures (return path)"
        if ! grep -q "^persist\.vendor\.softdog=" /data/local/tmp/gsi_persist_snapshot 2>/dev/null; then
            if [ -n "$(getprop persist.vendor.softdog 2>/dev/null)" ]; then
                if [ -n "$_SP_DELP" ]; then
                    "$_PR_RP" $_SP_DELP "$_SP_DEL" persist.vendor.softdog 2>/dev/null || true
                else
                    "$_PR_RP" "$_SP_DEL" persist.vendor.softdog 2>/dev/null || true
                fi
                # Second spelling as a fallback if the first did not clear it.
                if [ -n "$(getprop persist.vendor.softdog 2>/dev/null)" ]; then
                    "$_PR_RP" -d persist.vendor.softdog 2>/dev/null || true
                fi
                if [ -z "$(getprop persist.vendor.softdog 2>/dev/null)" ]; then
                    echo "PERSIST_RESTORE: persist.vendor.softdog deleted (set by a session, absent from snapshot)"
                else
                    echo "PERSIST_RESTORE_WARNING: could not delete persist.vendor.softdog (value stays; next switch's stale-snapshot recovery will retry)"
                fi
            fi
        fi
        if [ "$_pr_failed" -eq 0 ]; then
            rm -f /data/local/tmp/gsi_persist_snapshot /data/local/tmp/gsi_persist_spelling 2>/dev/null || true
        else
            echo "PERSIST_RESTORE_WARNING: snapshot kept (failures above) so a later return can retry"
        fi
    else
        echo "PERSIST_RESTORE_WARNING: no usable resetprop at return — persist.* snapshot NOT restored (next switch's stale-snapshot recovery will retry it)"
    fi
    unset _PR_RP _SP_SET _SP_DEL _SP_DELP _SP_LINE _SP_REST _pr_restored _pr_failed _pr_line _pr_name _pr_val
else
    echo "PERSIST_RESTORE_SKIPPED: no persist snapshot file (session started by an older build, or a previous return already restored it)"
fi
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
# 5.9.16: launcher UID/GID fallback logs LOUDLY. The old code fell
# back to 10160 silently if stat failed, so a wrong-UID restore could
# silently corrupt the home layout — the exact thing the launcher
# backup exists to protect. A fallback line below means: check the
# home layout after return; the restore may have used the wrong owner.
if LAUNCHER_UID_TMP="$(stat -c %u "$LAUNCHER_DATA" 2>/dev/null)" && [ -n "$LAUNCHER_UID_TMP" ]; then
    LAUNCHER_UID="$LAUNCHER_UID_TMP"
else
    echo "WARNING: LAUNCHER_UID_FALLBACK: stat failed for $LAUNCHER_DATA — falling back to UID 10160 (restore may use wrong ownership; check home layout after return)"
    LAUNCHER_UID=10160
fi
if LAUNCHER_GID_TMP="$(stat -c %g "$LAUNCHER_DATA" 2>/dev/null)" && [ -n "$LAUNCHER_GID_TMP" ]; then
    LAUNCHER_GID="$LAUNCHER_GID_TMP"
else
    echo "WARNING: LAUNCHER_GID_FALLBACK: stat failed for $LAUNCHER_DATA — falling back to GID 10160 (restore may use wrong ownership; check home layout after return)"
    LAUNCHER_GID=10160
fi

if [ -d "$BACKUP_DIR" ] && [ -d "$LAUNCHER_DATA/databases" ]; then
    cp -a "$BACKUP_DIR"/* "$LAUNCHER_DATA/databases/" 2>/dev/null || true
    chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 771 "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 660 "$LAUNCHER_DATA/databases"/* 2>/dev/null || true
    echo "One UI Home screen database restored with UID $LAUNCHER_UID:$LAUNCHER_GID"
fi
# 6.0 (P11): restore the host-layout extras backed up by
# backup_host.sh at takeover (shared_prefs, appwidgets, QS tiles).
# Separate dir from the legacy databases restore above, so the two
# restores cannot interfere. Failures are logged, never fatal.
_HOST_BACKUP="/data/local/tmp/gsi_host_backup"
if [ -d "$_HOST_BACKUP/shared_prefs" ]; then
    mkdir -p "$LAUNCHER_DATA/shared_prefs" 2>/dev/null || true
    cp -a "$_HOST_BACKUP/shared_prefs/"* "$LAUNCHER_DATA/shared_prefs/" 2>/dev/null || true
    chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/shared_prefs" 2>/dev/null || true
    echo "One UI launcher shared_prefs restored (6.0 host backup)"
fi
if [ -f "$_HOST_BACKUP/appwidgets.xml" ]; then
    cp -f "$_HOST_BACKUP/appwidgets.xml" /data/system/users/0/appwidgets.xml 2>/dev/null || true
    chown system:system /data/system/users/0/appwidgets.xml 2>/dev/null || true
    chmod 600 /data/system/users/0/appwidgets.xml 2>/dev/null || true
    echo "One UI appwidgets.xml restored (6.0 host backup)"
fi
if [ -f "$_HOST_BACKUP/sysui_qs_tiles.txt" ]; then
    _QS_SAVED="$(cat "$_HOST_BACKUP/sysui_qs_tiles.txt" 2>/dev/null)"
    if [ -n "$_QS_SAVED" ]; then
        settings put secure sysui_qs_tiles "$_QS_SAVED" 2>/dev/null && echo "One UI Quick Settings tiles restored (6.0 host backup)" || echo "HOST_BACKUP_WARN: could not restore QS tiles (continuing)"
    fi
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
# 5.9.16 per-step reporting: name the unmount result now, not only in
# the final RETURN_PARTIAL. A non-zero remaining count here is the
# stuck piece the final verdict will name as "unmount".
_REMAIN_MPTS="$(mount 2>/dev/null | grep -F 'lineage_stage' | grep -F 'rootfs' | wc -l 2>/dev/null || echo unknown)"
echo "RETURN_STEP unmounts: passes_used=$n remaining_lineage_rootfs_mounts=$_REMAIN_MPTS (0 = clean)"

echo "=== [4/5] Restoring Storage Mounts ==="
umount -l /storage/emulated 2>/dev/null || true
umount -l /mnt/user/0/emulated 2>/dev/null || true
mkdir -p /storage/emulated/0
if mount --bind /data/media/0 /storage/emulated/0 2>/dev/null; then
    echo "RETURN_STEP storage: /storage/emulated/0 bind OK"
else
    echo "RETURN_STEP storage: WARNING /storage/emulated/0 bind FAILED (storage may be unavailable in One UI until reboot)"
    add_failed storage
fi

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
# 5.9.16 per-step reporting: name each restarted service's read-back
# state, so a PARTIAL return names the service that did not come back.
if command -v getprop >/dev/null 2>&1; then
    for _svc in surfaceflinger zygote audioserver cameraserver media media.extractor media.metrics wificond; do
        echo "RETURN_STEP service: $_svc=$(getprop init.svc.$_svc 2>/dev/null || echo unknown)"
    done
else
    echo "RETURN_STEP service: getprop unavailable — service states unverified"
fi

# switch_to_gsi.sh drops SELinux to permissive for the takeover; restore it.
setenforce 1 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
echo "RETURN_STEP selinux: mode=$(getenforce 2>/dev/null || echo unknown) (expected Enforcing)"
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
# 5.9.16: per-step verify summary — a PARTIAL now names its stuck
# piece in this line as well as in the FAILED_STEPS list above.
echo "RETURN_STEP verify: unmount_failed=$(case " $FAILED_STEPS " in *" unmount "*) echo yes;; *) echo no;; esac) zygote_failed=$(case " $FAILED_STEPS " in *" zygote "*) echo yes;; *) echo no;; esac) setenforce_failed=$(case " $FAILED_STEPS " in *" setenforce "*) echo yes;; *) echo no;; esac) storage_failed=$(case " $FAILED_STEPS " in *" storage "*) echo yes;; *) echo no;; esac) failed_steps=[$FAILED_STEPS]"
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

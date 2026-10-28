#!/system/bin/sh
# boot_diagnostics.sh <slotDir> (GSI Loader Samsung 5.9.13)
#
# Captures a bounded guest-boot diagnostic bundle AFTER a failed boot.
# Called by boot_watchdog.sh on timeout, BEFORE it runs the return —
# so the guest is still up (mounts present, logs fresh) when the
# bundle is taken. The app surfaces this file on next launch
# (surfaceWatchdogOutcome) so a failed boot — especially an EROFS
# crash — is diagnosable from the app log alone.
#
# Strictly read-only diagnostics: it mounts, writes (except this
# one file), kills, or deletes nothing. Every section is bounded
# (tail/head) so the file stays small. If a source is unavailable
# (no logcat, no dmesg), the section says so instead of failing.
# The guest's logcat is visible from the host because /dev is
# rbind-mounted into the guest (shared logd); if that ever stops
# being true, the logcat sections will say so rather than lie.
SLOT_DIR="${1:-/data/local/tmp/lineage_stage}"
OUT="$SLOT_DIR/boot_diagnostics.log"
{
echo "=== BOOT DIAGNOSTICS $(date 2>/dev/null || echo unknown) slot=$SLOT_DIR ==="
echo "--- system.raw filesystem (magic bytes) ---"
if [ -f "$SLOT_DIR/system.raw" ]; then
    _me="$(dd if="$SLOT_DIR/system.raw" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    _mr="$(dd if="$SLOT_DIR/system.raw" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [ "$_me" = "53ef" ]; then echo "system.raw: ext4"
    elif [ "$_mr" = "e2e1f5e0" ]; then echo "system.raw: erofs"
    else echo "system.raw: unknown (ext4 magic='$_me' erofs magic='$_mr')"
    fi
else
    echo "system.raw: MISSING (no image installed for this slot)"
fi
echo "--- guest rootfs mounts (host namespace) ---"
_mnt="$(mount 2>/dev/null | grep -F "lineage_stage" | head -30)"
if [ -n "$_mnt" ]; then printf '%s\n' "$_mnt"; else echo "(no lineage_stage mounts)"; fi
echo "--- takeover log (switch_to_gsi.sh output, last 60) ---"
tail -60 "$SLOT_DIR/takeover_app.log" 2>/dev/null || echo "(no takeover_app.log)"
echo "--- inner takeover log (master_inner.sh output, last 60) ---"
tail -60 "$SLOT_DIR/data/takeover.log" 2>/dev/null || echo "(no data/takeover.log)"
echo "--- watchdog log (last 40) ---"
tail -40 "$SLOT_DIR/boot_watchdog.log" 2>/dev/null || echo "(no boot_watchdog.log)"
echo "--- host logcat crash buffer (last 40) ---"
logcat -d -b crash 2>/dev/null | tail -40 || echo "(logcat crash buffer unavailable)"
echo "--- host logcat system: FATAL / AndroidRuntime / EIO / erofs (last 40) ---"
logcat -d -b system 2>/dev/null | grep -a -E "FATAL|AndroidRuntime|system_server.*(crash|died|FATAL)|EIO|erofs" | tail -40 || echo "(no matching logcat lines)"
echo "--- kernel erofs errors (dmesg, last 20) ---"
dmesg 2>/dev/null | grep -a -i "erofs" | tail -20 || echo "(no erofs dmesg lines or dmesg unavailable)"
echo "--- guest processes still alive? ---"
ps -ef 2>/dev/null | grep -v grep | grep -F "$SLOT_DIR/rootfs" | head -10 || echo "(no guest-rooted processes listed)"
echo "--- watchdog node identity / timeout / timeleft (5.9.16) ---"
ls -l /dev/watchdog* 2>/dev/null || echo "(no /dev/watchdog* nodes)"
for _wd in /sys/class/watchdog/*; do
    [ -d "$_wd" ] || continue
    echo "watchdog $(basename "$_wd"): identity=$(cat "$_wd/identity" 2>/dev/null || echo unknown) timeout=$(cat "$_wd/timeout" 2>/dev/null || echo unknown) timeleft=$(cat "$_wd/timeleft" 2>/dev/null || echo unknown)"
done
echo "--- watchdog feeder / keepalive / guest kicker liveness (5.9.16) ---"
echo "feeder pidfile: $(cat /data/local/tmp/gsi_watchdog_feeder.pid 2>/dev/null || echo none)"
ps -ef 2>/dev/null | grep -v grep | grep -E "gsi_watchdog_supervisor.sh|gsi_watchdog_feeder.sh|host_watchdogd_keepalive.sh|gsi_guest_kicker" | head -10 || echo "(no feeder/keepalive/kicker processes listed)"
echo "host watchdogd: pid=$(pidof watchdogd 2>/dev/null || echo none) init.svc.watchdogd=$(getprop init.svc.watchdogd 2>/dev/null || echo unknown)"
echo "--- watchdog feeder log (last 20) ---"
tail -20 /data/local/tmp/gsi_watchdog_feeder.log 2>/dev/null || echo "(no gsi_watchdog_feeder.log)"
echo "--- guest kicker log (last 20) ---"
tail -20 "$SLOT_DIR/data/guest_watchdog_kicker.log" 2>/dev/null || echo "(no guest kicker log in slot data)"
echo "--- SELinux mode (5.9.16) ---"
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
echo "--- kernel DEFEX / RKP / sec_watchdog lines (dmesg, last 20) (5.9.16) ---"
dmesg 2>/dev/null | grep -a -i -E "defex|rkp|sec_watchdog" | tail -20 || echo "(no DEFEX/RKP/sec_watchdog dmesg lines or dmesg unavailable)"
echo "=== END BOOT DIAGNOSTICS ==="
} > "$OUT" 2>/dev/null
echo "BOOT_DIAGNOSTICS_WRITTEN: $OUT"

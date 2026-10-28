#!/system/bin/sh
# pstore_check.sh (GSI Loader Samsung 5.9.13)
#
# Answers ONE question after an unexpected reboot ended a guest
# session: did the previous boot end in a KERNEL PANIC, or was the
# reboot userspace-initiated (RescueParty, a service-triggered
# reboot, or a manual force-restart)?
#
# How it works: the kernel's pstore (persistent storage, ramoops)
# keeps the previous boot's console log across ANY reboot. If that
# log contains a panic signature, the previous boot panicked the
# kernel. If pstore exists but holds no panic signature, the
# previous boot did not panic — its reboot came from userspace (or
# the power button). /proc/last_kmsg is checked the same way on
# kernels that still provide it (pstore replaces it on modern ones).
#
# WHEN the app runs this: ONLY when its launch sweep cleared a stale
# .guest_running marker — i.e. the last guest session ended WITHOUT
# a Return (a reboot or force-restart). A panic found here therefore
# happened while a guest session was open. That correlation is the
# whole point: it is what separates "the EROFS guest panicked the
# kernel" from "the guest service crashed and something rebooted".
#
# Caveat, stated plainly: pstore persists across boots, and a panic
# from an EARLIER host crash (no guest involved) could still be
# sitting there when a later guest session ends by force-restart.
# The erofs/loop lines in the excerpt are the tie-breaker: a panic
# trace naming erofs (especially on a loop device, which is how the
# guest image is mounted) points at the guest's EROFS reads, while a
# panic with no erofs context points elsewhere. The verdict line
# says what was FOUND, not what caused the guest session to end.
#
# Report-once, non-destructive: files already reported are recorded
# (name + hash) in /data/local/tmp/pstore_consumed and skipped on
# later runs, so each panic is surfaced once. Nothing in pstore is
# deleted — the raw evidence stays for adb pull if ever needed.
# If a source is unavailable, the verdict says so (UNAVAILABLE /
# EMPTY) instead of guessing.
#
# Output: a VERDICT line first, then a bounded excerpt.
#   PSTORE_PANIC [EROFS_HINT] — a panic is recorded (erofs lines
#     present => the EROFS driver path is the prime suspect and the
#     EXT4 preset avoids that driver entirely).
#   PSTORE_NO_PANIC — pstore/last_kmsg exist but hold no panic
#     signature: the reboot was userspace or manual, NOT a panic.
#   PSTORE_EMPTY — the pstore dir exists but holds no previous-boot
#     log (nothing recorded, or all entries already reported).
#   PSTORE_UNAVAILABLE — no pstore dir and no last_kmsg (kernel
#     lacks pstore/ramoops, or it is not mounted — this script does
#     NOT mount it; that would change system state from a diagnostic).
#
# Test override (VM harness only; never set on the phone):
#   PSTORE_DIR — pstore directory, default /sys/fs/pstore
PSTORE_DIR="${PSTORE_DIR:-/sys/fs/pstore}"
CONSUMED="/data/local/tmp/pstore_consumed"

_hash_file() {
    _f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_f" 2>/dev/null | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$_f" 2>/dev/null | awk '{print $1}'
    else
        wc -c < "$_f" 2>/dev/null | tr -d ' '
    fi
}

# Collect candidate previous-boot logs: pstore console/dmesg dumps
# plus last_kmsg when present. Each entry is "path" (one per line).
_cands=""
if [ -d "$PSTORE_DIR" ]; then
    for _f in "$PSTORE_DIR"/console-ramoops* "$PSTORE_DIR"/dmesg-ramoops*; do
        [ -f "$_f" ] && _cands="$_cands
$_f"
    done
fi
if [ -f /proc/last_kmsg ]; then
    _cands="$_cands
/proc/last_kmsg"
fi
# Drop the leading blank line the construction above leaves.
_cands="$(printf '%s' "$_cands" | grep -v '^$')"

if [ -z "$_cands" ]; then
    if [ -d "$PSTORE_DIR" ]; then
        echo "PSTORE_EMPTY: pstore dir exists but holds no previous-boot log (nothing recorded, or all entries already reported)"
    else
        echo "PSTORE_UNAVAILABLE: no pstore dir ($PSTORE_DIR) and no /proc/last_kmsg — kernel lacks pstore/ramoops or it is not mounted"
    fi
    exit 0
fi

_found_panic=0
_found_erofs=0
_reported=0
_sections=""
for _f in $_cands; do
    [ -f "$_f" ] || continue
    _h="$(_hash_file "$_f")"
    # Skip entries already reported on an earlier launch.
    if [ -f "$CONSUMED" ] && grep -q -F "$_f $_h" "$CONSUMED" 2>/dev/null; then
        continue
    fi
    _reported=1
    if grep -a -q -i -e "kernel panic" -e "BUG:" -e "call trace" -e "Oops" "$_f" 2>/dev/null; then
        _found_panic=1
        _sections="$_sections
--- panic lines in $_f ---
$(grep -a -i -e "kernel panic" -e "BUG:" -e "call trace" -e "Oops" "$_f" 2>/dev/null | head -10)"
        if grep -a -q -i "erofs" "$_f" 2>/dev/null; then
            _found_erofs=1
            _sections="$_sections
--- erofs lines in $_f ---
$(grep -a -i "erofs" "$_f" 2>/dev/null | head -10)"
        fi
        _sections="$_sections
--- tail of $_f (last 15) ---
$(tail -15 "$_f" 2>/dev/null)"
    else
        _sections="$_sections
--- $_f: no panic signature (last 5) ---
$(tail -5 "$_f" 2>/dev/null)"
    fi
    # Record as reported (best-effort; a failure here just means a
    # possible repeat report on a later launch, never lost evidence).
    printf '%s %s\n' "$_f" "$_h" >> "$CONSUMED" 2>/dev/null || true
done

if [ "$_reported" = "0" ]; then
    echo "PSTORE_EMPTY: all previous-boot logs were already reported on an earlier launch (nothing new)"
    exit 0
fi
if [ "$_found_panic" = "1" ]; then
    if [ "$_found_erofs" = "1" ]; then
        echo "PSTORE_PANIC EROFS_HINT: a kernel panic IS recorded and its trace mentions erofs — the EROFS driver path is the prime suspect for the reboot; the EXT4 preset avoids that driver entirely"
    else
        echo "PSTORE_PANIC: a kernel panic IS recorded, but its trace does not mention erofs — the reboot was a kernel panic, not a guest-service crash"
    fi
else
    echo "PSTORE_NO_PANIC: previous-boot log(s) examined, no panic signature — the reboot was userspace-initiated (RescueParty, a service-triggered reboot) or manual, NOT a kernel panic"
fi
printf '%s\n' "$_sections" | grep -v '^$' | head -100
exit 0

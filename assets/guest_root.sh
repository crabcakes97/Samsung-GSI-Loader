#!/system/bin/sh
# guest_root.sh <stageDir> <on|off>  (5.9.5, POSIX sh)
# HONESTY NOTE (read before integrating): no su binary asset exists in
# this tree, and this script does not invent one. What "on" actually does:
#   1. Detects a host su binary AT RUNTIME from common host paths
#      (/data/adb/ksu/bin/su, /data/adb/ksud, /data/adb/magisk/*,
#      $(command -v su), /system/bin/su, /system/xbin/su, /sbin/su).
#   2. Stages the boot hook (guest_root_hook.sh, written next to this
#      script's stage copy) and the flag file guest_root.enabled, so
#      master_prepare.sh / master_inner.sh bind-mount that detected
#      host su into the guest at boot (see the GUEST_ROOT hooks there).
#   3. Prints GUEST_ROOT_ON only when a host su was actually found now.
#      If none is found now, it prints GUEST_ROOT_UNSUPPORTED
#      host-su-not-found, leaves NO enabled flag behind, and exits 1 —
#      it never prints ON for work it did not do.
# What "on" does NOT do (the gap, stated plainly): it does not give
# guest APPS root through a standard su app/daemon flow. A bind-mounted
# host su gives a root SHELL / root commands from the host side (see
# guest_root_shell.sh, which runs host-root commands inside the guest
# mount namespace while the guest is running), but guest apps calling
# su still go through the host su's own grant policy, which is keyed
# to host app identities — there is no guest-side su daemon in this
# tree to grant guest apps root. Installing a su binary into the
# guest image offline is deliberately NOT done: there is no su asset
# to install, and copying a host su into a read-only EROFS image is
# not possible offline anyway. No image file is modified by this script.
# "off" removes the flag file (the hook becomes inert) and prints
# GUEST_ROOT_OFF.
STAGE="$1"
MODE="$2"
if [ -z "$STAGE" ] || [ -z "$MODE" ]; then
    echo "GUEST_ROOT_ERROR: usage: guest_root.sh <stageDir> <on|off>" >&2
    exit 1
fi
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
elif [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
else
    echo "GUEST_ROOT_ERROR: guards.sh not found" >&2
    exit 1
fi
gsi_validate_stage "$STAGE" || { echo "GUEST_ROOT_ERROR: INVALID_STAGE: $STAGE" >&2; exit 1; }
# Runtime host-su detection (no bundled binary, no hardcoded grant).
# Android host paths ONLY. A generic `command -v su` is deliberately
# NOT used: on a Linux VM that resolves to /usr/bin/su, which is not
# an Android root su and bind-mounting it into a guest would be nonsense.
find_host_su() {
    for _p in /data/adb/ksu/bin/su /data/adb/ksud /data/adb/magisk/su /data/adb/ap/bin/su /system/bin/su /system/xbin/su /sbin/su; do
        if [ -f "$_p" ]; then
            printf '%s' "$_p"
            return 0
        fi
    done
    return 1
}
case "$MODE" in
    off)
        rm -f "$STAGE/guest_root.enabled" 2>/dev/null || true
        echo "GUEST_ROOT_OFF"
        exit 0
        ;;
    on)
        ;;
    *)
        echo "GUEST_ROOT_ERROR: mode must be on or off" >&2
        exit 1
        ;;
esac
SU_PATH=""
SU_PATH="$(find_host_su 2>/dev/null)" || SU_PATH=""
# Stage the boot hook regardless of detection outcome: it re-detects
# at boot time (a su that appears between staging and boot is then used).
# The flag file, which actually activates it, is written only on success.
cat > "$STAGE/guest_root_hook.sh" <<'HOOK'
#!/system/bin/sh
# guest_root_hook.sh — run by master_prepare.sh at guest boot when
# GUEST_ROOT=1 or $STAGE/guest_root.enabled exists. Re-detects the host
# su at boot time and bind-mounts it over the guest's /system/xbin/su.
# It never claims success without a bind: it logs SU_BIND_OK <path> or
# SU_BIND_FAIL <reason> to stdout and returns 0/1 accordingly.
HOOK_STAGE="$1"
HOOK_ROOTFS="$2"
[ -n "$HOOK_STAGE" ] && [ -n "$HOOK_ROOTFS" ] || exit 1
_HB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$_HB" ] || _HB="mount"
for _p in /data/adb/ksu/bin/su /data/adb/ksud /data/adb/magisk/su /data/adb/ap/bin/su /system/bin/su /system/xbin/su /sbin/su; do
    if [ -f "$_p" ]; then _SU="$_p"; break; fi
done
[ -n "${_SU:-}" ] || { echo "SU_BIND_FAIL host-su-not-found"; exit 1; }
mkdir -p "$HOOK_ROOTFS/system/xbin" 2>/dev/null || true
if ! mount 2>/dev/null | grep -q "$HOOK_ROOTFS/system/xbin "; then
    $_HB mount -t tmpfs tmpfs "$HOOK_ROOTFS/system/xbin" 2>/dev/null || mount -t tmpfs tmpfs "$HOOK_ROOTFS/system/xbin" 2>/dev/null || true
fi
$_HB mount --bind "$_SU" "$HOOK_ROOTFS/system/xbin/su" 2>/dev/null || mount --bind "$_SU" "$HOOK_ROOTFS/system/xbin/su" 2>/dev/null || { echo "SU_BIND_FAIL bind-failed"; exit 1; }
chmod 755 "$HOOK_ROOTFS/system/xbin/su" 2>/dev/null || true
echo "SU_BIND_OK $_SU"
exit 0
HOOK
chmod 755 "$STAGE/guest_root_hook.sh" 2>/dev/null || true
if [ -n "$SU_PATH" ]; then
    printf '%s\n' "$SU_PATH" > "$STAGE/guest_root.enabled" 2>/dev/null || { echo "GUEST_ROOT_ERROR: cannot write flag file" >&2; exit 1; }
    echo "GUEST_ROOT_ON"
    exit 0
else
    rm -f "$STAGE/guest_root.enabled" 2>/dev/null || true
    echo "GUEST_ROOT_UNSUPPORTED host-su-not-found"
    exit 1
fi

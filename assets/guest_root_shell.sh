#!/system/bin/sh
# guest_root_shell.sh <stageDir> <command...>  (5.9.5, POSIX sh)
# The real guest-root SHELL path that guest_root.sh documents: when the
# guest for this slot is running and this script runs as host root, it
# runs the given command inside the guest's mount namespace via nsenter
# into the guest system_server process (found by scanning for a process
# whose root is under <stageDir>/rootfs and whose cmdline mentions
# system_server; any guest-rootfs process is used as a fallback).
# If the guest is not running, or nsenter / a guest process cannot be
# found, it fails loudly instead of pretending to run inside the guest.
# This is a host-root shell into the guest, NOT a grant of root to
# guest apps (see guest_root.sh's honesty note).
STAGE="$1"
[ -n "$STAGE" ] || { echo "GUEST_ROOT_SHELL_ERROR: usage: guest_root_shell.sh <stageDir> <command...>" >&2; exit 1; }
shift
[ $# -ge 1 ] || { echo "GUEST_ROOT_SHELL_ERROR: no command given" >&2; exit 1; }
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
elif [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
else
    echo "GUEST_ROOT_SHELL_ERROR: guards.sh not found" >&2
    exit 1
fi
gsi_validate_stage "$STAGE" || { echo "GUEST_ROOT_SHELL_ERROR: INVALID_STAGE: $STAGE" >&2; exit 1; }
gsi_guest_running "$STAGE" || { echo "GUEST_ROOT_SHELL_ERROR: guest not running for $STAGE" >&2; exit 1; }
command -v nsenter >/dev/null 2>&1 || { echo "GUEST_ROOT_SHELL_ERROR: nsenter not available" >&2; exit 1; }
ROOTFS="$STAGE/rootfs"
PR="$(gsi_proc_root)"
TARGET=""
FALLBACK=""
for _d in "$PR"/[0-9]*; do
    [ -d "$_d" ] || continue
    _rl="$(readlink "$_d/root" 2>/dev/null)"
    case "$_rl" in
        "$ROOTFS"|"$ROOTFS"/*) ;;
        *) continue ;;
    esac
    _pid="${_d##*/}"
    [ -z "$FALLBACK" ] && FALLBACK="$_pid"
    _cl="$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)"
    case "$_cl" in
        *system_server*) TARGET="$_pid"; break ;;
    esac
done
[ -n "$TARGET" ] || TARGET="$FALLBACK"
[ -n "$TARGET" ] || { echo "GUEST_ROOT_SHELL_ERROR: no guest process found to nsenter" >&2; exit 1; }
exec nsenter -t "$TARGET" -m -- /system/bin/sh -c "$*"

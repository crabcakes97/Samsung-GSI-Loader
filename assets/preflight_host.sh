#!/system/bin/sh
# preflight_host.sh  (5.9.5, POSIX sh)
# Verifies the host is untouched before a guest boot:
#   1. /system /vendor /product /odm are mounted read-only (as stock).
#   2. No guest rootfs is mounted outside the staging root.
#   3. Staging containment: the staging root is not a symlink escape,
#      and no lineage_stage path is mounted outside the staging root.
# Prints "PREFLIGHT_OK" or "PREFLIGHT_FAIL <reason>"; exit 0/1.
# Test override (VM synthetic tests only): GSI_MOUNTS_FILE and
# GSI_STAGE_ROOT (see guards.sh). On device they are unset.
if [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
elif [ -f "/data/local/tmp/lineage_stage/guards.sh" ]; then
    . "/data/local/tmp/lineage_stage/guards.sh"
else
    echo "PREFLIGHT_FAIL guards.sh not found" >&2
    exit 1
fi
ROOT="$(gsi_stage_root)"
MF="$(gsi_mounts_file)"
[ -f "$MF" ] || { echo "PREFLIGHT_FAIL mounts file missing: $MF"; exit 1; }
# 1. Host partitions read-only. /proc/mounts lines are:
#    <device> <mountpoint> <fstype> <options> ...
#    Options are comma-separated; "ro" must be a whole option, not "rw".
for _mp in /system /vendor /product /odm; do
    _line="$(awk -v mp="$_mp" '$2 == mp {print; exit}' "$MF" 2>/dev/null)"
    [ -n "$_line" ] || { echo "PREFLIGHT_FAIL mount not found: $_mp"; exit 1; }
    _opts="$(printf '%s' "$_line" | awk '{print $4}')"
    case ",$_opts," in
        *,ro,*) ;;
        *) echo "PREFLIGHT_FAIL not read-only: $_mp ($_opts)"; exit 1 ;;
    esac
done
# 2+3. Guest rootfs / staging paths outside the staging root.
#    Any mountpoint ending in /rootfs that is not under $ROOT, and any
#    mountpoint containing lineage_stage that is not under $ROOT, fails.
#    (Mounts under $ROOT itself — e.g. a staged rootfs awaiting boot —
#    are not "outside staging" and do not fail this check.)
while IFS= read -r _line || [ -n "$_line" ]; do
    _mp="$(printf '%s' "$_line" | awk '{print $2}')"
    [ -n "$_mp" ] || continue
    case "$_mp" in
        */rootfs|*/rootfs/*)
            case "$_mp" in
                "$ROOT"/*) ;;
                *) echo "PREFLIGHT_FAIL guest rootfs mounted outside staging: $_mp"; exit 1 ;;
            esac
            ;;
    esac
    case "$_mp" in
        *lineage_stage*)
            case "$_mp" in
                "$ROOT"|"$ROOT"/*) ;;
                *) echo "PREFLIGHT_FAIL staging path mounted outside staging root: $_mp"; exit 1 ;;
            esac
            ;;
    esac
done < "$MF"
if [ -L "$ROOT" ]; then
    echo "PREFLIGHT_FAIL staging root is a symlink: $ROOT"; exit 1
fi
echo "PREFLIGHT_OK"
exit 0

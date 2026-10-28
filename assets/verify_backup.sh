#!/system/bin/sh
# verify_backup.sh <backupDir>  (5.9.5, POSIX sh)
# Recomputes sha256s against meta, then either mount-checks system.raw
# (read-only loop mount, looking for system/bin/sh + init.environ.rc)
# when loop mounting is possible, or falls back to structural checks
# (ext4 magic 53ef @1080 / EROFS magic e2e1f5e0 @1024, size consistency).
# Prints "VERIFY_OK" or "VERIFY_FAIL <reason>"; exit 0 on OK, 1 on FAIL.
# A mount attempt that fails (no loop device, not root, dummy test file)
# is NOT a failure by itself: it falls through to the structural checks.
BACKUP="$1"
if [ -z "$BACKUP" ]; then
    echo "VERIFY_FAIL usage: verify_backup.sh <backupDir>" >&2
    exit 1
fi
if [ -f "$BACKUP/guards.sh" ]; then
    . "$BACKUP/guards.sh"
elif [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
else
    # verify takes a backup dir, not a stage dir, so guards may legitimately
    # not sit beside it; fall back to the script's own directory only.
    echo "VERIFY_FAIL guards.sh not found" >&2
    exit 1
fi
# Containment: the backup must live under the staging root (so a stray
# path cannot be "verified" as a backup). Test harnesses set GSI_STAGE_ROOT.
gsi_require_contained "$BACKUP" || { echo "VERIFY_FAIL outside staging root: $BACKUP"; exit 1; }
_BASENAME="$(basename "$BACKUP")"
gsi_validate_name "$_BASENAME" || { echo "VERIFY_FAIL invalid backup name: $_BASENAME"; exit 1; }
[ -f "$BACKUP/system.raw" ] || { echo "VERIFY_FAIL system.raw missing"; exit 1; }
[ -f "$BACKUP/meta" ] || { echo "VERIFY_FAIL meta missing"; exit 1; }
WANT_SHA="$(grep '^system_raw_sha256=' "$BACKUP/meta" 2>/dev/null | cut -d= -f2)"
WANT_SIZE="$(grep '^system_raw_size=' "$BACKUP/meta" 2>/dev/null | cut -d= -f2)"
DATA_PRESENT="$(grep '^data_present=' "$BACKUP/meta" 2>/dev/null | cut -d= -f2)"
if [ -n "$WANT_SHA" ]; then
    GOT_SHA="$(gsi_sha256 "$BACKUP/system.raw")"
    [ "$GOT_SHA" = "$WANT_SHA" ] || { echo "VERIFY_FAIL system.raw sha256 mismatch"; exit 1; }
fi
if [ -n "$WANT_SIZE" ]; then
    GOT_SIZE="$(stat -c %s "$BACKUP/system.raw" 2>/dev/null || echo 0)"
    [ "$GOT_SIZE" = "$WANT_SIZE" ] || { echo "VERIFY_FAIL system.raw size mismatch"; exit 1; }
fi
if [ "$DATA_PRESENT" = "1" ] && [ ! -d "$BACKUP/data" ]; then
    echo "VERIFY_FAIL data dir missing but meta says data_present=1"; exit 1
fi
if [ -f "$BACKUP/data_manifest.txt" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -n "$_line" ] || continue
        _h="${_line%%  *}"
        _rel="${_line#*  }"
        [ "$_rel" = "$_line" ] && { echo "VERIFY_FAIL malformed manifest line"; exit 1; }
        [ -f "$BACKUP/data/$_rel" ] || { echo "VERIFY_FAIL data file missing: $_rel"; exit 1; }
        _got="$(gsi_sha256 "$BACKUP/data/$_rel")"
        [ "$_got" = "$_h" ] || { echo "VERIFY_FAIL data sha256 mismatch: $_rel"; exit 1; }
    done < "$BACKUP/data_manifest.txt"
fi
# Mount check when possible, else structural checks.
FSTYPE="$(gsi_fs_type "$BACKUP/system.raw")"
MOUNTED_OK=0
MOUNT_TRIED=0
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && command -v mount >/dev/null 2>&1; then
    MNT="$(mktemp -d 2>/dev/null || echo "")"
    if [ -n "$MNT" ] && [ -d "$MNT" ]; then
        MOUNT_TRIED=1
        if mount -t "$FSTYPE" -o ro,loop "$BACKUP/system.raw" "$MNT" 2>/dev/null; then
            :
        elif command -v losetup >/dev/null 2>&1; then
            _LOOP="$(losetup -f 2>/dev/null)"
            if [ -n "$_LOOP" ] && losetup "$_LOOP" "$BACKUP/system.raw" 2>/dev/null && mount -t "$FSTYPE" -o ro "$_LOOP" "$MNT" 2>/dev/null; then
                :
            else
                [ -n "$_LOOP" ] && losetup -d "$_LOOP" 2>/dev/null || true
                _LOOP=""
            fi
            if [ -n "$_LOOP" ]; then
                if [ -f "$MNT/system/bin/sh" ] && [ -f "$MNT/init.environ.rc" ]; then
                    MOUNTED_OK=1
                else
                    umount "$MNT" 2>/dev/null || true
                    losetup -d "$_LOOP" 2>/dev/null || true
                    rmdir "$MNT" 2>/dev/null || true
                    echo "VERIFY_FAIL mounted image lacks system/bin/sh or init.environ.rc"; exit 1
                fi
                umount "$MNT" 2>/dev/null || true
                losetup -d "$_LOOP" 2>/dev/null || true
                rmdir "$MNT" 2>/dev/null || true
                echo "VERIFY_OK"
                exit 0
            fi
        fi
        if [ -f "$MNT/system/bin/sh" ] && [ -f "$MNT/init.environ.rc" ]; then
            # Reached only via the first mount path (loop already mounted).
            :
        elif mount | grep -q " $MNT " 2>/dev/null; then
            umount "$MNT" 2>/dev/null || true
            rmdir "$MNT" 2>/dev/null || true
            echo "VERIFY_FAIL mounted image lacks system/bin/sh or init.environ.rc"; exit 1
        fi
        if mount | grep -q " $MNT " 2>/dev/null; then
            if [ -f "$MNT/system/bin/sh" ] && [ -f "$MNT/init.environ.rc" ]; then
                MOUNTED_OK=1
            else
                umount "$MNT" 2>/dev/null || true
                rmdir "$MNT" 2>/dev/null || true
                echo "VERIFY_FAIL mounted image lacks system/bin/sh or init.environ.rc"; exit 1
            fi
            umount "$MNT" 2>/dev/null || true
        fi
        rmdir "$MNT" 2>/dev/null || true
    fi
fi
if [ "$MOUNTED_OK" = "1" ]; then
    echo "VERIFY_OK"
    exit 0
fi
# Structural fallback (also the path taken when mounting is impossible).
case "$FSTYPE" in
    ext4|erofs) ;;
    *) echo "VERIFY_FAIL unknown filesystem magic (not ext4/EROFS)"; exit 1 ;;
esac
_SZ="$(stat -c %s "$BACKUP/system.raw" 2>/dev/null || echo 0)"
[ "$_SZ" -gt 2048 ] || { echo "VERIFY_FAIL system.raw too small for its magic offsets"; exit 1; }
if [ "$MOUNT_TRIED" = "1" ]; then
    echo "VERIFY_OK"
else
    echo "VERIFY_OK"
fi
exit 0

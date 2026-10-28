#!/system/bin/sh
# backup_slot.sh <stageDir> <backupName>  (5.9.5, POSIX sh)
# Multi-generation backup: creates <stageDir>/backups/<backupName>/
# containing system.raw + data dir + meta (timestamp, slot, sha256s,
# sizes) + data_manifest.txt (per-file sha256 for the data tree, so
# verify_backup.sh can recompute them). NEVER overwrites an existing
# backup name (collision -> error, exit 1). Creation is staged in a
# .tmp directory and renamed into place.
# Prints "BACKUP_OK <path> <system.raw sha256>".
# This REPLACES the old single-.bak concept with generations. The old
# .bak path is untouched Java code (not edited here): an existing
# system.raw.bak is still restorable by that Java path, and manually
# with: cp system.raw.bak system.raw.new && mv system.raw.new system.raw
# (after returning to One UI). This script deliberately does not
# overwrite or delete any .bak file.
# Note: unlike snapshot/rollback, backup does NOT refuse while the
# guest is running (the contract does not require it, and backup is
# read-only), but it warns on stderr if the guest is running, because
# a live guest's data copy may be inconsistent.
STAGE="$1"
NAME="$2"
if [ -z "$STAGE" ] || [ -z "$NAME" ]; then
    echo "BACKUP_ERROR: usage: backup_slot.sh <stageDir> <backupName>" >&2
    exit 1
fi
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
elif [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
else
    echo "BACKUP_ERROR: guards.sh not found" >&2
    exit 1
fi
gsi_validate_stage "$STAGE" || { echo "BACKUP_ERROR: INVALID_STAGE: $STAGE" >&2; exit 1; }
gsi_validate_name "$NAME" || { echo "BACKUP_ERROR: INVALID_NAME: $NAME" >&2; exit 1; }
if gsi_guest_running "$STAGE"; then
    echo "BACKUP_WARNING: guest for $STAGE appears to be running; data copy may be inconsistent" >&2
fi
[ -f "$STAGE/system.raw" ] || { echo "BACKUP_ERROR: system.raw missing in $STAGE" >&2; exit 1; }
BACKDIR="$STAGE/backups/$NAME"
[ -e "$BACKDIR" ] && { echo "BACKUP_ERROR: backup already exists (refusing to overwrite): $BACKDIR" >&2; exit 1; }
mkdir -p "$STAGE/backups" || { echo "BACKUP_ERROR: cannot create backups dir" >&2; exit 1; }
TMP="$STAGE/backups/.${NAME}.tmp.$$"
rm -rf "$TMP" 2>/dev/null
mkdir -p "$TMP" || { echo "BACKUP_ERROR: cannot create staging dir" >&2; exit 1; }
cleanup() { rm -rf "$TMP" 2>/dev/null; }
cp -f "$STAGE/system.raw" "$TMP/system.raw" 2>/dev/null || { echo "BACKUP_ERROR: system.raw copy failed" >&2; cleanup; exit 1; }
if [ -d "$STAGE/data" ]; then
    cp -a "$STAGE/data" "$TMP/data" 2>/dev/null || { echo "BACKUP_ERROR: data copy failed" >&2; cleanup; exit 1; }
    DATA_PRESENT=1
else
    mkdir -p "$TMP/data"
    DATA_PRESENT=0
fi
SHA="$(gsi_sha256 "$TMP/system.raw")"
[ -n "$SHA" ] || { echo "BACKUP_ERROR: sha256 unavailable" >&2; cleanup; exit 1; }
SIZE="$(stat -c %s "$TMP/system.raw" 2>/dev/null || echo 0)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
SLOT="$(gsi_slot_name "$STAGE")"
DATA_COUNT=0
if [ -d "$TMP/data" ]; then
    DATA_COUNT="$(find "$TMP/data" -type f 2>/dev/null | wc -l | tr -d ' ')"
fi
{
    printf 'timestamp=%s\n' "$TS"
    printf 'slot=%s\n' "$SLOT"
    printf 'system_raw_sha256=%s\n' "$SHA"
    printf 'system_raw_size=%s\n' "$SIZE"
    printf 'data_present=%s\n' "$DATA_PRESENT"
    printf 'data_file_count=%s\n' "$DATA_COUNT"
} > "$TMP/meta" || { echo "BACKUP_ERROR: meta write failed" >&2; cleanup; exit 1; }
# Per-file data manifest (sha256 + relative path). Dash-compatible:
# plain `find | while IFS= read -r` (no -print0 / read -d, which dash
# does not support). This handles spaces in filenames; filenames
# containing newlines are not supported by the manifest format (the
# copy itself, via cp -a, still handles them).
: > "$TMP/data_manifest.txt" || { echo "BACKUP_ERROR: manifest write failed" >&2; cleanup; exit 1; }
if [ -d "$TMP/data" ]; then
    find "$TMP/data" -type f 2>/dev/null | while IFS= read -r _f; do
        _rel="${_f#$TMP/data/}"
        _h="$(gsi_sha256 "$_f")"
        printf '%s  %s\n' "$_h" "$_rel" >> "$TMP/data_manifest.txt" 2>/dev/null || true
    done
fi
mv "$TMP" "$BACKDIR" || { echo "BACKUP_ERROR: rename failed" >&2; cleanup; exit 1; }
echo "BACKUP_OK $BACKDIR $SHA"
exit 0

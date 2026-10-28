#!/system/bin/sh
# snapshot_slot.sh <stageDir> <snapshotName>  (5.9.5, POSIX sh)
# Creates <stageDir>/snapshots/<snapshotName>/ containing a copy of
# system.raw, a copy of the slot's data dir, and a meta file
# (timestamp, slot, system.raw sha256). Prints "SNAPSHOT_OK <path>".
# Refuses invalid snapshot names ([A-Za-z0-9_-]{1,32}), refuses if the
# guest for that slot is currently running, and refuses to overwrite
# an existing snapshot of the same name. Creation is staged in a
# .tmp directory and renamed into place, so a failed snapshot never
# leaves a half-written snapshot behind.
STAGE="$1"
NAME="$2"
if [ -z "$STAGE" ] || [ -z "$NAME" ]; then
    echo "SNAPSHOT_ERROR: usage: snapshot_slot.sh <stageDir> <snapshotName>" >&2
    exit 1
fi
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
elif [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
else
    echo "SNAPSHOT_ERROR: guards.sh not found (expected in stage dir or beside this script)" >&2
    exit 1
fi
gsi_validate_stage "$STAGE" || { echo "SNAPSHOT_ERROR: INVALID_STAGE: $STAGE" >&2; exit 1; }
gsi_validate_name "$NAME" || { echo "SNAPSHOT_ERROR: INVALID_NAME: $NAME" >&2; exit 1; }
gsi_require_not_running "$STAGE" || exit 1
[ -f "$STAGE/system.raw" ] || { echo "SNAPSHOT_ERROR: system.raw missing in $STAGE" >&2; exit 1; }
SNAPDIR="$STAGE/snapshots/$NAME"
[ -e "$SNAPDIR" ] && { echo "SNAPSHOT_ERROR: snapshot already exists: $SNAPDIR" >&2; exit 1; }
mkdir -p "$STAGE/snapshots" || { echo "SNAPSHOT_ERROR: cannot create snapshots dir" >&2; exit 1; }
TMP="$STAGE/snapshots/.${NAME}.tmp.$$"
rm -rf "$TMP" 2>/dev/null
mkdir -p "$TMP" || { echo "SNAPSHOT_ERROR: cannot create staging dir" >&2; exit 1; }
cleanup() { rm -rf "$TMP" 2>/dev/null; }
cp -f "$STAGE/system.raw" "$TMP/system.raw" 2>/dev/null || { echo "SNAPSHOT_ERROR: system.raw copy failed" >&2; cleanup; exit 1; }
if [ -d "$STAGE/data" ]; then
    cp -a "$STAGE/data" "$TMP/data" 2>/dev/null || { echo "SNAPSHOT_ERROR: data copy failed" >&2; cleanup; exit 1; }
    DATA_PRESENT=1
else
    mkdir -p "$TMP/data"
    DATA_PRESENT=0
fi
SHA="$(gsi_sha256 "$TMP/system.raw")"
[ -n "$SHA" ] || { echo "SNAPSHOT_ERROR: sha256 unavailable" >&2; cleanup; exit 1; }
SIZE="$(stat -c %s "$TMP/system.raw" 2>/dev/null || echo 0)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
SLOT="$(gsi_slot_name "$STAGE")"
{
    printf 'timestamp=%s\n' "$TS"
    printf 'slot=%s\n' "$SLOT"
    printf 'system_raw_sha256=%s\n' "$SHA"
    printf 'system_raw_size=%s\n' "$SIZE"
    printf 'data_present=%s\n' "$DATA_PRESENT"
} > "$TMP/meta" || { echo "SNAPSHOT_ERROR: meta write failed" >&2; cleanup; exit 1; }
mv "$TMP" "$SNAPDIR" || { echo "SNAPSHOT_ERROR: rename failed" >&2; cleanup; exit 1; }
echo "SNAPSHOT_OK $SNAPDIR"
exit 0

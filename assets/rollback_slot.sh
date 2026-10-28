#!/system/bin/sh
# rollback_slot.sh <stageDir> <snapshotName>  (5.9.5, POSIX sh)
# Restores system.raw + data dir from <stageDir>/snapshots/<snapshotName>/
# ATOMICALLY: the new system.raw is staged as system.raw.new, size- and
# sha-checked against the snapshot meta, then renamed over system.raw,
# so a failure never leaves a half-restored system.raw. The data dir is
# restored the same way (new tree staged, old tree moved aside, new
# tree moved in, old tree removed; on failure the old tree is put back).
# Refuses invalid names and refuses while that slot's guest is running.
# Prints "ROLLBACK_OK". Errors go to stderr, exit 1.
STAGE="$1"
NAME="$2"
if [ -z "$STAGE" ] || [ -z "$NAME" ]; then
    echo "ROLLBACK_ERROR: usage: rollback_slot.sh <stageDir> <snapshotName>" >&2
    exit 1
fi
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
elif [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
else
    echo "ROLLBACK_ERROR: guards.sh not found" >&2
    exit 1
fi
gsi_validate_stage "$STAGE" || { echo "ROLLBACK_ERROR: INVALID_STAGE: $STAGE" >&2; exit 1; }
gsi_validate_name "$NAME" || { echo "ROLLBACK_ERROR: INVALID_NAME: $NAME" >&2; exit 1; }
gsi_require_not_running "$STAGE" || exit 1
SNAPDIR="$STAGE/snapshots/$NAME"
[ -f "$SNAPDIR/system.raw" ] || { echo "ROLLBACK_ERROR: snapshot not found or incomplete: $SNAPDIR" >&2; exit 1; }
if [ -f "$SNAPDIR/meta" ]; then
    WANT_SHA="$(grep '^system_raw_sha256=' "$SNAPDIR/meta" 2>/dev/null | cut -d= -f2)"
    WANT_SIZE="$(grep '^system_raw_size=' "$SNAPDIR/meta" 2>/dev/null | cut -d= -f2)"
    if [ -n "$WANT_SHA" ]; then
        GOT_SHA="$(gsi_sha256 "$SNAPDIR/system.raw")"
        [ "$GOT_SHA" = "$WANT_SHA" ] || { echo "ROLLBACK_ERROR: snapshot system.raw sha256 mismatch (corrupt snapshot)" >&2; exit 1; }
    fi
    if [ -n "$WANT_SIZE" ]; then
        GOT_SIZE="$(stat -c %s "$SNAPDIR/system.raw" 2>/dev/null || echo 0)"
        [ "$GOT_SIZE" = "$WANT_SIZE" ] || { echo "ROLLBACK_ERROR: snapshot system.raw size mismatch" >&2; exit 1; }
    fi
fi
TMP="$STAGE/system.raw.new"
rm -f "$TMP" 2>/dev/null
cp -f "$SNAPDIR/system.raw" "$TMP" 2>/dev/null || { echo "ROLLBACK_ERROR: staging copy failed" >&2; rm -f "$TMP" 2>/dev/null; exit 1; }
SRC_SIZE="$(stat -c %s "$SNAPDIR/system.raw" 2>/dev/null || echo 0)"
GOT_SIZE="$(stat -c %s "$TMP" 2>/dev/null || echo 0)"
if [ "$GOT_SIZE" != "$SRC_SIZE" ]; then
    echo "ROLLBACK_ERROR: staged copy truncated" >&2; rm -f "$TMP" 2>/dev/null; exit 1
fi
chmod 644 "$TMP" 2>/dev/null || true
mv -f "$TMP" "$STAGE/system.raw" || { echo "ROLLBACK_ERROR: rename failed (old system.raw untouched only if rename did not run)" >&2; rm -f "$TMP" 2>/dev/null; exit 1; }
# Data dir restore (only if the snapshot carries one).
if [ -d "$SNAPDIR/data" ]; then
    NEWDATA="$STAGE/data.new.$$"
    OLDDATA="$STAGE/data.old.$$"
    rm -rf "$NEWDATA" "$OLDDATA" 2>/dev/null
    cp -a "$SNAPDIR/data" "$NEWDATA" 2>/dev/null || { echo "ROLLBACK_ERROR: data staging copy failed (system.raw already restored)" >&2; rm -rf "$NEWDATA" 2>/dev/null; exit 1; }
    if [ -d "$STAGE/data" ]; then
        mv "$STAGE/data" "$OLDDATA" || { echo "ROLLBACK_ERROR: could not move old data aside" >&2; rm -rf "$NEWDATA" 2>/dev/null; exit 1; }
    fi
    if mv "$NEWDATA" "$STAGE/data"; then
        rm -rf "$OLDDATA" 2>/dev/null || true
    else
        echo "ROLLBACK_ERROR: data move-in failed, restoring old data" >&2
        [ -d "$OLDDATA" ] && mv "$OLDDATA" "$STAGE/data" 2>/dev/null || true
        exit 1
    fi
fi
echo "ROLLBACK_OK"
exit 0

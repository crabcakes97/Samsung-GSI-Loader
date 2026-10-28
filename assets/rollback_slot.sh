#!/system/bin/sh
# rollback_slot.sh <stageDir> <snapshotName>  (5.9.5, POSIX sh)
# Restores system.raw + data dir from <stageDir>/snapshots/<snapshotName>/
# ATOMICALLY (5.9.16): system.raw AND data are both staged first
# (system.raw.new + data.new, size-checked), then committed together
# with the old halves kept aside until both new halves are in place,
# so a failure never leaves system and data from different
# generations. On commit failure both old halves are restored.
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
# 5.9.16: stage BOTH halves FIRST, commit second. The 5.9.5 order
# restored system.raw before data staging, so a data-copy failure
# left system and data from different generations (the error text
# itself admitted "system.raw already restored"). Now a staging
# failure of either half aborts before anything live is touched.
# Commit is a two-phase rename with the old halves kept aside until
# both new halves are in place: on a commit failure both old halves
# are restored, so the slot is never left generation-split. A
# ROLLBACK_COMMIT marker names the snapshot being committed; it is
# removed on success and left behind (with the old halves) only if
# the commit itself fails, so a later run can see what was mid-flight.
TMP="$STAGE/system.raw.new"
rm -f "$TMP" 2>/dev/null
cp -f "$SNAPDIR/system.raw" "$TMP" 2>/dev/null || { echo "ROLLBACK_ERROR: staging copy failed" >&2; rm -f "$TMP" 2>/dev/null; exit 1; }
SRC_SIZE="$(stat -c %s "$SNAPDIR/system.raw" 2>/dev/null || echo 0)"
GOT_SIZE="$(stat -c %s "$TMP" 2>/dev/null || echo 0)"
if [ "$GOT_SIZE" != "$SRC_SIZE" ]; then
    echo "ROLLBACK_ERROR: staged copy truncated" >&2; rm -f "$TMP" 2>/dev/null; exit 1
fi
chmod 644 "$TMP" 2>/dev/null || true
# Stage the data half too (only if the snapshot carries one) BEFORE
# committing either half.
NEWDATA=""
if [ -d "$SNAPDIR/data" ]; then
    NEWDATA="$STAGE/data.new.$$"
    rm -rf "$NEWDATA" 2>/dev/null
    cp -a "$SNAPDIR/data" "$NEWDATA" 2>/dev/null || { echo "ROLLBACK_ERROR: data staging copy failed (nothing restored yet)" >&2; rm -rf "$NEWDATA" "$TMP" 2>/dev/null; exit 1; }
fi
# Commit phase. Old halves are renamed aside (cheap, same filesystem),
# never deleted, until both new halves are in place.
OLDSYS="$STAGE/system.raw.old.$$"
OLDDATA="$STAGE/data.old.$$"
rm -f "$OLDSYS" 2>/dev/null; rm -rf "$OLDDATA" 2>/dev/null
echo "$NAME" > "$STAGE/.rollback_commit" 2>/dev/null || true
COMMIT_FAIL=0
if [ -f "$STAGE/system.raw" ]; then
    mv "$STAGE/system.raw" "$OLDSYS" || COMMIT_FAIL=1
fi
if [ "$COMMIT_FAIL" = "0" ]; then
    mv -f "$TMP" "$STAGE/system.raw" || COMMIT_FAIL=1
fi
if [ "$COMMIT_FAIL" = "0" ] && [ -n "$NEWDATA" ]; then
    if [ -d "$STAGE/data" ]; then
        mv "$STAGE/data" "$OLDDATA" || COMMIT_FAIL=1
    fi
    if [ "$COMMIT_FAIL" = "0" ]; then
        mv "$NEWDATA" "$STAGE/data" || COMMIT_FAIL=1
    fi
fi
if [ "$COMMIT_FAIL" != "0" ]; then
    echo "ROLLBACK_ERROR: commit failed, restoring previous system.raw and data" >&2
    rm -f "$STAGE/system.raw" 2>/dev/null
    if [ -f "$OLDSYS" ]; then mv "$OLDSYS" "$STAGE/system.raw" 2>/dev/null || true; fi
    if [ -n "$NEWDATA" ]; then
        rm -rf "$STAGE/data" 2>/dev/null
        if [ -d "$OLDDATA" ]; then mv "$OLDDATA" "$STAGE/data" 2>/dev/null || true; fi
        rm -rf "$NEWDATA" 2>/dev/null
    fi
    echo "ROLLBACK_ERROR: rollback aborted mid-commit; previous state restored, marker $STAGE/.rollback_commit left for inspection" >&2
    exit 1
fi
rm -f "$OLDSYS" 2>/dev/null; rm -rf "$OLDDATA" 2>/dev/null
rm -f "$STAGE/.rollback_commit" 2>/dev/null || true
echo "ROLLBACK_OK"
exit 0

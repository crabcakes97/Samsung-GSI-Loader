#!/system/bin/sh
# check_slot_guard.sh <stageDir>  (5.9.5, POSIX sh)
# Thin wrapper around guards.sh for the Java wipe/delete paths, which
# live in Java and are not edited by the scripts workstream. Java can
# call this before any destructive slot operation and refuse unless it
# prints GUARD_OK:
#   sh check_slot_guard.sh <stageDir>  ->  "GUARD_OK" (exit 0) or
#   "GUARD_RUNNING" / "GUARD_ERROR ..." (exit 1).
# It validates stage containment and refuses while the guest is running,
# using exactly the detection method documented in guards.sh.
STAGE="$1"
if [ -z "$STAGE" ]; then
    echo "GUARD_ERROR usage: check_slot_guard.sh <stageDir>" >&2
    exit 1
fi
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
elif [ -f "$(dirname "$0")/guards.sh" ]; then
    . "$(dirname "$0")/guards.sh"
else
    echo "GUARD_ERROR guards.sh not found" >&2
    exit 1
fi
gsi_validate_stage "$STAGE" || { echo "GUARD_ERROR INVALID_STAGE: $STAGE"; exit 1; }
if gsi_guest_running "$STAGE"; then
    echo "GUARD_RUNNING"
    exit 1
fi
echo "GUARD_OK"
exit 0

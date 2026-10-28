#!/system/bin/sh
# guards.sh — shared 5.9.5 safety snippet, sourced (never executed directly).
# Sourced by: snapshot_slot.sh, rollback_slot.sh, backup_slot.sh,
# verify_backup.sh, guest_root.sh, install_image.sh, switch_to_gsi.sh,
# master_prepare.sh, and the check_slot_guard.sh wrapper (for the Java
# wipe/delete paths, which live in Java and are not edited here).
#
# Detection method (guest-running), documented for the coordinator:
#   A slot's guest counts as RUNNING only on LIVE evidence:
#   1. The mounts file lists "$stage/rootfs" itself or any submount
#      under it (host-namespace mounts created by master_prepare.sh).
#   2. Any process (scanned under $GSI_PROC_ROOT, default /proc) has
#      its root directory under "$stage/rootfs" (readlink /proc/PID/root),
#      or its cmdline mentions "$stage/rootfs" (e.g. master_inner.sh).
#   3. A takeover script (switch_to_gsi.sh / master_prepare.sh) for
#      this stage is currently running (its cmdline names the stage
#      dir). This covers the window before the rootfs mount exists
#      (e.g. the IMS gate) when the app may have been relaunched
#      mid-takeover; the caller's own PID is always skipped so a
#      script never matches itself.
#   The "$stage/.guest_running" marker file is NOT a running signal
#   (5.9.13): switch_to_gsi.sh creates it at takeover and only
#   return_to_oneui.sh removes it, so a force-restart — which never
#   runs the return script — leaves a stale marker behind forever,
#   and every guard then false-positives ("a guest is running" when
#   none is). The marker is still created/removed by those scripts
#   as an informational breadcrumb, and the app's launch sweep plus
#   Return's light path delete stale ones — but no guard decision
#   reads it anymore. A genuinely running guest always has its
#   rootfs mounted (master_prepare.sh mounts it in the host
#   namespace before the takeover daemon launches), so mount/process
#   evidence is present for the whole live session: dropping the
#   marker signal removes false positives without introducing false
#   negatives.
#   Name-based process kills are NOT used as a detection signal here:
#   host daemons share names with guest daemons (zygote64,
#   surfaceflinger, system_server), so a bare name match would also
#   match the host when no guest is running.
#
# Test overrides (VM synthetic tests only; on device they are unset):
#   GSI_STAGE_ROOT   — staging root, default /data/local/tmp/lineage_stage
#   GSI_MOUNTS_FILE  — mounts file, default /proc/mounts
#   GSI_PROC_ROOT    — proc root, default /proc
# All functions are POSIX sh, quote their arguments, and never exit
# the sourcing script themselves except via explicit return codes.
# Sourcing twice is a no-op.
if [ -n "$GSI_GUARDS_LOADED" ]; then
    :
else
    GSI_GUARDS_LOADED=1

    gsi_stage_root() {
        if [ -n "$GSI_STAGE_ROOT" ]; then
            printf '%s' "$GSI_STAGE_ROOT"
        else
            printf '%s' "/data/local/tmp/lineage_stage"
        fi
    }

    gsi_mounts_file() {
        if [ -n "$GSI_MOUNTS_FILE" ]; then
            printf '%s' "$GSI_MOUNTS_FILE"
        else
            printf '%s' "/proc/mounts"
        fi
    }

    gsi_proc_root() {
        if [ -n "$GSI_PROC_ROOT" ]; then
            printf '%s' "$GSI_PROC_ROOT"
        else
            printf '%s' "/proc"
        fi
    }

    # gsi_validate_name <name> — 1-32 chars, [A-Za-z0-9_-] only.
    gsi_validate_name() {
        _n="$1"
        case "$_n" in
            ''|*[!A-Za-z0-9_-]*) return 1 ;;
        esac
        [ "${#_n}" -ge 1 ] && [ "${#_n}" -le 32 ]
    }

    # gsi_strip_trailing_slash <path> — prints path without trailing /.
    gsi_strip_trailing_slash() {
        _p="$1"
        while [ "$_p" != "/" ]; do
            case "$_p" in
                */) _p="${_p%/}" ;;
                *) break ;;
            esac
        done
        printf '%s' "$_p"
    }

    # gsi_validate_stage <dir> — dir must be the staging root itself or
    # <root>/slots/<valid name> (exactly one component, no traversal).
    gsi_validate_stage() {
        _root="$(gsi_stage_root)"
        _d="$(gsi_strip_trailing_slash "$1")"
        [ -n "$_d" ] || return 1
        if [ "$_d" = "$_root" ]; then
            return 0
        fi
        case "$_d" in
            "$_root"/slots/*)
                _slot="${_d##*/slots/}"
                case "$_slot" in
                    *"/"*) return 1 ;;
                esac
                gsi_validate_name "$_slot"
                return $?
                ;;
            *) return 1 ;;
        esac
    }

    # gsi_slot_name <stageDir> — "Default" for the root, else slot name.
    gsi_slot_name() {
        _root="$(gsi_stage_root)"
        _d="$(gsi_strip_trailing_slash "$1")"
        if [ "$_d" = "$_root" ]; then
            printf '%s' "Default"
        else
            printf '%s' "${_d##*/slots/}"
        fi
    }

    # gsi_require_contained <path> — path must be the staging root or
    # under it, with no ".." component. Returns 0/1.
    gsi_require_contained() {
        _root="$(gsi_stage_root)"
        _p="$(gsi_strip_trailing_slash "$1")"
        case "$_p" in
            *"/../"*|*".."/*|*/"..") return 1 ;;
        esac
        case "$_p" in
            "$_root"|"$_root"/*) return 0 ;;
            *) return 1 ;;
        esac
    }

    # gsi_guest_running <stageDir> — 0 if running (see header), else 1.
    # 5.9.13: LIVENESS ONLY — the .guest_running marker is deliberately
    # NOT consulted (see header: a force-restart leaves it stale
    # forever). A takeover-in-progress also counts (signal 3), so a
    # destructive op cannot race a takeover the app was relaunched
    # during; the caller's own PID is skipped so a script never
    # matches itself.
    gsi_guest_running() {
        _stage="$(gsi_strip_trailing_slash "$1")"
        _rootfs="$_stage/rootfs"
        _mf="$(gsi_mounts_file)"
        if [ -f "$_mf" ]; then
            if grep -F -q -e " $_rootfs " -e " $_rootfs/" "$_mf" 2>/dev/null; then
                return 0
            fi
        fi
        _pr="$(gsi_proc_root)"
        for _d in "$_pr"/[0-9]*; do
            [ -d "$_d" ] || continue
            _pid="${_d##*/}"
            [ "$_pid" = "$$" ] && continue
            _rl="$(readlink "$_d/root" 2>/dev/null)"
            case "$_rl" in
                "$_rootfs"|"$_rootfs"/*) return 0 ;;
            esac
            if [ -f "$_d/cmdline" ]; then
                _cl="$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)"
                case "$_cl" in
                    *"$_rootfs"*) return 0 ;;
                esac
                # Takeover in progress for exactly this stage: the
                # stage dir is the script's (last) argument, so it is
                # followed by end-of-cmdline or a space — never by
                # more path components. That exactness matters: a
                # slot takeover (".../slots/foo") must NOT block the
                # parent root stage's guard (its path merely starts
                # with the root path).
                case "$_cl" in
                    *"switch_to_gsi.sh $_stage"|*"switch_to_gsi.sh $_stage "*|*"master_prepare.sh $_stage"|*"master_prepare.sh $_stage "*) return 0 ;;
                esac
            fi
        done
        return 1
    }

    # gsi_require_not_running <stageDir> — stderr + return 1 if running.
    gsi_require_not_running() {
        if gsi_guest_running "$1"; then
            echo "GUARD_RUNNING: guest for stage '$1' is running — return to One UI first" >&2
            return 1
        fi
        return 0
    }

    # gsi_sha256 <file> — prints hex digest only, or nothing on failure.
    gsi_sha256() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" 2>/dev/null | awk '{print $1}'
        elif command -v busybox >/dev/null 2>&1; then
            busybox sha256sum "$1" 2>/dev/null | awk '{print $1}'
        else
            printf '%s' ""
        fi
    }

    # gsi_fs_type <file> — prints ext4, erofs, sparse, or unknown.
    gsi_fs_type() {
        _f="$1"
        [ -f "$_f" ] || { printf '%s' "unknown"; return 0; }
        _m0="$(od -An -tx1 -N4 "$_f" 2>/dev/null | tr -d ' \n')"
        if [ "$_m0" = "3aff26ed" ]; then
            printf '%s' "sparse"; return 0
        fi
        _me="$(dd if="$_f" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        _mr="$(dd if="$_f" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        if [ "$_me" = "53ef" ]; then
            printf '%s' "ext4"; return 0
        fi
        if [ "$_mr" = "e2e1f5e0" ]; then
            printf '%s' "erofs"; return 0
        fi
        printf '%s' "unknown"
    }
fi

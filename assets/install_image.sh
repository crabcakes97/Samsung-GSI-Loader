#!/system/bin/sh
# install_image.sh — turn a picked or downloaded GSI file into $OUT safely.
# Usage: install_image.sh <input> <move 0|1> <stage> <system.raw>
#   move=1 (downloads) may consume the input file when it IS the image;
#   move=0 (user local files) never deletes the user's file.
# Rules, in order:
#   1. Reject formats the bundled 7zz 23.01 cannot unpack (.zst, raw .lz4/.br).
#   2. Archive inputs are extracted with 7zz (raw .img inputs skip
#      extraction — 5.9.10: running 7zz x on a raw image always fails
#      and broke local .img installs in 5.9.9). ALL stale stage files
#      are cleaned first:
#      every *.img at any depth, every other file over 100 MB (the
#      fallback's threshold — a stale blob used to survive and poison
#      the count into AMBIGUOUS even though the archive itself holds a
#      single image), plus stale system.raw.new/.converted temps from
#      crashed installs. The working system.raw is NEVER deleted before
#      the new one is validated — a failed install must not destroy the
#      GSI that boots. The input file itself is never deleted even if
#      it ever lives inside the stage dir. Stage infrastructure (7zz,
#      simg2img, scripts) is far below 100 MB and is never a .img, so
#      the sweep cannot touch it.
#   3. Pick a candidate: exact system.img/system_a.img/system_b.img
#      (recursive, maxdepth 3), then *system*.img excluding system_ext,
#      then any *.img (one -> use it; several -> the LARGEST, logged),
#      then a single large non-.img extracted file (not the input, not
#      system.raw). AMBIGUOUS only fires when several large non-.img
#      files exist and no .img at all, and it prints the full candidate
#      list (path + size) so the failure is diagnosable.
#   4. Reject super.img (LP container, not a filesystem) by name.
#   5. Sparse images (magic 0xED26FF3A) are converted with the bundled
#      aarch64 simg2img (assets/simg2img, built from
#      anestisb/android-simg2img with the NDK clang) when it is present
#      in $STAGE, falling back to /data/local/tmp/lineage_stage/simg2img
#      (the Default stage copy) when a named slot lacks its own; the
#      converted size is verified against the sparse header
#      (total_blks * blk_sz) before install. If simg2img is missing or
#      conversion fails, fail loudly instead of installing garbage
#      that cannot mount.
#   6. Detect the filesystem (ext4 magic 53ef @1080, EROFS magic e2e1f5e0
#      @1024) and reject anything else.
#   7. Free-space check: candidate size + 10% headroom on the stage fs.
#   8. Atomic install: copy to system.raw.new, size-check it, then rename
#      over system.raw. Any failure leaves the old system.raw intact.
# 5.9.9: archive inputs are integrity-tested (7zz t) BEFORE the sweep
#      or extraction, and 7zz's exit code is checked with its error tail
#      captured to a stage log — a resumed download across a mirror
#      redirect can assemble a corrupt archive that still has the right
#      byte count, and blindly extracting it used to die downstream
#      with a confusing error (5.9.8 on-device: CANDIDATE_EMPTY) because
#      7zz's exit code was ignored and its output discarded. Test fails
#      -> DOWNLOAD_CORRUPT; extract fails -> EXTRACT_FAILED. The
#      CANDIDATE_EMPTY failure prints the candidate path, its ls output
#      and the magic-check values so a recurrence is explainable.
# 5.9.10: 32-bit shell integer overflow — the REAL 5.9.9 on-device
#      cause. The phone's test builtin is 32-bit: a 3446353920-byte
#      GAPPS image wraps to a negative number, so [ "$SIZE" -le 0 ]
#      was TRUE for a perfectly good 3.2 GB image and 5.9.9 died with
#      CANDIDATE_EMPTY on a CLEAN download (no abort, no resume) —
#      the 5.9.9 corruption theory is dead. Rule from here on: NO
#      shell integer test or $(( )) in this script may operate on
#      raw byte sizes. Emptiness is [ ! -s ]; thresholds, free-space
#      and sparse checks go through awk doubles (exact for integers
#      below 2^53); byte sizes are otherwise only printed or
#      string-compared. Counts (NIMG, N) and MB values are small and
#      may still use shell tests.
# All failures print INSTALL_ERROR: <reason> and exit 1.
# 5.9.16: the sweep is logged + whitelisted (backups, snapshots,
# slots, data, rootfs never swept); long steps emit INSTALL_PROGRESS
# markers to $STAGE/install_progress.log for the app poller; a
# pre-install fit check prints FIT_WARNING when the guest SDK is
# older than the host vendor SDK; format rejects print the exact
# conversion to run instead of a bare unsupported line; and 7zz /
# simg2img are hash-checked against .engine_hashes when present.
INPUT="$1"
MOVE="$2"
STAGE="$3"
OUT="$4"
CONVERTED_FILE=""
PROGRESS_FILE=""
PROGRESS_FLAG=""
fail() { [ -n "$PROGRESS_PID" ] && kill "$PROGRESS_PID" 2>/dev/null || true; [ -n "$CONVERTED_FILE" ] && rm -f "$CONVERTED_FILE" 2>/dev/null || true; [ -n "$PROGRESS_FLAG" ] && rm -f "$PROGRESS_FLAG" 2>/dev/null || true; [ -n "$PROGRESS_FILE" ] && echo "INSTALL_PROGRESS: failed" >> "$PROGRESS_FILE" 2>/dev/null || true; echo "INSTALL_ERROR: $1"; exit 1; }
# 5.9.16 install progress markers. Long steps (7zz extraction of a
# ~1 GB archive, simg2img conversion of a ~2.7 GB sparse image) used
# to run silent for minutes, which already produced force-restarts
# mid-install. Now each long step runs a background tick loop that
# appends INSTALL_PROGRESS lines to $STAGE/install_progress.log
# every 5 s; the app polls that file (same pattern as
# streamBootProgress polling takeover_app.log). The loop is bounded
# by a flag file holding the script's PID: removing the flag stops
# it, and if the script dies the PID check stops it too, so a
# failed install never leaves a stray tick loop behind. Ticks are
# diagnostic only — they never gate the install.
progress_start() {
    # $1 = label, $2 = mode (stage|file), $3 = probe file (file mode),
    # $4 = expected MB (file mode, 0 when unknown).
    PROGRESS_FLAG="$STAGE/.install_progress_active"
    echo "$$" > "$PROGRESS_FLAG" 2>/dev/null || true
    (
        _label="$1"; _mode="$2"; _file="$3"; _exp="$4"
        while [ -f "$PROGRESS_FLAG" ] && kill -0 "$(cat "$PROGRESS_FLAG" 2>/dev/null)" 2>/dev/null; do
            if [ "$_mode" = "file" ]; then
                _sz="$(stat -c %s "$_file" 2>/dev/null || echo 0)"
                _mb="$(awk -v s="$_sz" 'BEGIN{printf "%d", s/1048576}' 2>/dev/null || echo 0)"
                if [ "$_exp" != "0" ] && [ -n "$_exp" ]; then
                    echo "INSTALL_PROGRESS: $_label ($_mb MB of ~$_exp MB written)" >> "$PROGRESS_FILE" 2>/dev/null
                else
                    echo "INSTALL_PROGRESS: $_label ($_mb MB written)" >> "$PROGRESS_FILE" 2>/dev/null
                fi
            else
                _kb="$(du -sk "$STAGE" 2>/dev/null | cut -f1)"
                echo "INSTALL_PROGRESS: $_label (stage ${_kb} KB and growing)" >> "$PROGRESS_FILE" 2>/dev/null
            fi
            sleep 5
        done
    ) &
    PROGRESS_PID=$!
}
progress_stop() {
    [ -n "$PROGRESS_FLAG" ] && rm -f "$PROGRESS_FLAG" 2>/dev/null || true
    [ -n "$PROGRESS_PID" ] && kill "$PROGRESS_PID" 2>/dev/null || true
    [ -n "$PROGRESS_PID" ] && wait "$PROGRESS_PID" 2>/dev/null || true
    PROGRESS_PID=""
}

[ -n "$INPUT" ] && [ -n "$STAGE" ] && [ -n "$OUT" ] || fail "BAD_ARGUMENTS"
case "$STAGE" in
    /data/local/tmp/lineage_stage) ;;
    /data/local/tmp/lineage_stage/slots/*)
        SLOTNAME="${STAGE##*/slots/}"
        case "$SLOTNAME" in
            ''|*/*|*[!A-Za-z0-9_-]*) fail "INVALID_STAGE: $STAGE" ;;
        esac
        ;;
    *) fail "INVALID_STAGE: $STAGE" ;;
esac
[ "$(dirname "$OUT")" = "$STAGE" ] || fail "OUTSIDE_STAGE: output must live inside the stage dir"
# 5.9.5-SCRIPTS-START: destructive-op guard (guards.sh). Installing
# overwrites system.raw, so refuse while this slot's guest is running.
# If guards.sh has not been extracted to the stage yet, the legacy
# stage validation above still applies and install proceeds.
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
    gsi_validate_stage "$STAGE" || fail "INVALID_STAGE: $STAGE"
    gsi_guest_running "$STAGE" && fail "SLOT_RUNNING: guest for this slot is running — return to One UI first"
fi
# 5.9.5-SCRIPTS-END
[ -f "$INPUT" ] || fail "INPUT_MISSING"

case "$INPUT" in
    *.zst|*.zstd) fail "UNSUPPORTED_COMPRESSION: .zst needs a newer extractor than the bundled 7zz 23.01 — convert it first, then install the result: on a PC run 'zstd -d file.zst' (or on-device if zstd is installed), or re-download the EXT4/EROFS .7z preset instead" ;;
    *.lz4) fail "UNSUPPORTED_COMPRESSION: raw .lz4 frames are not supported by the bundled extractor — convert it first, then install the result: run 'lz4 -d file.lz4' to get the raw image (lz4 must be installed), then install that raw image" ;;
    *.br) fail "UNSUPPORTED_COMPRESSION: raw .br frames are not supported by the bundled extractor — convert it first, then install the result: run 'brotli -d file.br' to get the raw image (brotli must be installed), then install that raw image" ;;
esac

mkdir -p "$STAGE" || fail "STAGE_MKDIR_FAILED"
# 5.9.9: the extractor must exist, and archive inputs must pass an
# integrity test BEFORE anything is wiped or extracted. A resumed
# download across a mirror redirect can assemble a corrupt archive
# that still has the right byte count; extracting it blindly used to
# fail downstream with a confusing error (5.9.8 on-device:
# CANDIDATE_EMPTY) because 7zz's exit code was ignored and its output
# discarded. Test fails -> DOWNLOAD_CORRUPT (the app deletes the bad
# download and fetches a fresh copy); extract fails -> EXTRACT_FAILED
# with 7zz's error tail. Logs live in the stage dir (small files,
# never swept, never .img) so the next report shows why.
[ -x "$STAGE/7zz" ] || fail "EXTRACTOR_MISSING: bundled 7zz not found in stage dir"
# 5.9.16: progress file for the app's install poller (created here,
# after the sweep point below would have removed any stale one only
# if it were >100 MB — it never is — and before the long steps).
PROGRESS_FILE="$STAGE/install_progress.log"
echo "INSTALL_PROGRESS: starting install" > "$PROGRESS_FILE" 2>/dev/null || true
# 5.9.16: engine tool hash check. The app's engine sync records
# SHA-256 hashes of the big binaries in $STAGE/.engine_hashes (slot
# sync) or the Default stage copy (install copies 7zz/simg2img
# without writing a hash file, so fall back to that one). If a hash
# file exists and a tool's hash mismatches, the extractor/converter
# is stale or corrupt — fail loudly instead of installing from it.
# No hash file means the old behaviour (proceed); a hash file that
# lacks a tool also proceeds for that tool.
_HASHFILE="$STAGE/.engine_hashes"
if [ ! -f "$_HASHFILE" ] && [ "$STAGE" != "/data/local/tmp/lineage_stage" ]; then
    [ -f "/data/local/tmp/lineage_stage/.engine_hashes" ] && _HASHFILE="/data/local/tmp/lineage_stage/.engine_hashes"
fi
if [ -f "$_HASHFILE" ] && type gsi_sha256 >/dev/null 2>&1; then
    for _tool in 7zz simg2img; do
        [ -f "$STAGE/$_tool" ] || continue
        _want="$(awk -v t="$_tool" '$2 == t {print $1}' "$_HASHFILE" 2>/dev/null | head -n 1)"
        [ -n "$_want" ] || continue
        _got="$(gsi_sha256 "$STAGE/$_tool" 2>/dev/null)"
        [ "$_got" = "$_want" ] || fail "TOOL_HASH_MISMATCH: $STAGE/$_tool does not match the engine hash recorded by the app — re-launch the app to re-sync the engine before installing (a stale/corrupt extractor or converter must not install anything)"
    done
fi
case "$INPUT" in
    *.7z|*.zip|*.xz|*.gz|*.tgz|*.tar)
        TESTLOG="$STAGE/archive-test.log"
        "$STAGE/7zz" t "$INPUT" >"$TESTLOG" 2>&1 || {
            INPSIZE=$(stat -c %s "$INPUT" 2>/dev/null || echo 0)
            echo "DOWNLOAD_CORRUPT: archive integrity test (7zz t) failed for $INPUT ($INPSIZE bytes) — the download is corrupt, likely from a resumed/interrupted transfer; delete it and download a fresh copy (not a resume):"
            tail -n 10 "$TESTLOG" 2>/dev/null
            fail "DOWNLOAD_CORRUPT: archive failed integrity test ($INPUT, $INPSIZE bytes; 7zz error above)"
        }
        ;;
esac
# 5.9.8: clean ALL stale stage files, not just top-level *.img.
# A previous run's nested .img (e.g. inside an archive subfolder) or any
# other stale file over 100 MB used to survive and poison the fallback
# count into AMBIGUOUS — the confirmed 5.9.7 failure mode: the MisterZtr
# 23.2 VANILLA archive itself holds exactly one image, so the extra
# large files came from the stage dir. The working system.raw is never
# touched here (it is not a .img and is excluded from the size sweep);
# stale .new / .converted temps from crashed installs are dropped too
# (the atomic rename below is the only thing that may replace
# system.raw). The input file is excluded from both sweeps.
# 5.9.16: logged, whitelisted sweep. The old sweep deleted every
# *.img and every >100 MB file under the stage dir without saying
# what it deleted — and that included user data that merely lives
# under the stage dir (backups/, snapshots/, other slots/, guest
# data/, and the mounted rootfs tree). Now every swept path is
# logged with its size BEFORE deletion, and paths outside the
# whitelist are refused: backups, snapshots, slots, data and rootfs
# subtrees are never swept, nor are the input, the output
# (system.raw), or any file literally named system.raw anywhere.
find "$STAGE" \( -path "$STAGE/backups" -o -path "$STAGE/snapshots" -o -path "$STAGE/slots" -o -path "$STAGE/data" -o -path "$STAGE/rootfs" \) -prune -o -type f \( -name '*.img' -o -size +100M \) -print 2>/dev/null > "$STAGE/.sweep_list" || true
while IFS= read -r _sweep || [ -n "$_sweep" ]; do
    [ -n "$_sweep" ] || continue
    case "$_sweep" in
        "$STAGE/backups/"*|"$STAGE/snapshots/"*|"$STAGE/slots/"*|"$STAGE/data/"*|"$STAGE/rootfs/"*) echo "SWEEP_SKIP: protected path kept: $_sweep"; continue ;;
        "$INPUT"|"$OUT") echo "SWEEP_SKIP: input/output kept: $_sweep"; continue ;;
        */system.raw) echo "SWEEP_SKIP: system.raw kept: $_sweep"; continue ;;
    esac
    _ssz="$(stat -c %s "$_sweep" 2>/dev/null || echo 0)"
    echo "SWEEP: deleting $_sweep ($_ssz bytes)"
    rm -f "$_sweep" 2>/dev/null || echo "SWEEP_WARN: could not delete $_sweep"
done < "$STAGE/.sweep_list"
rm -f "$STAGE/.sweep_list" 2>/dev/null
rm -f "$OUT.new" "$OUT.converted" 2>/dev/null
echo "SWEEP: stale temps $OUT.new and $OUT.converted removed (if present)"
# 5.9.9: 7zz's exit code used to be ignored and its output discarded,
# so a failed extraction slid silently into candidate selection and
# died with a confusing error. Now a failed extraction fails loudly
# with 7zz's error tail attached.
# 5.9.10: extraction runs ONLY for archives. It used to run for every
# input, so a raw local .img (which 7zz cannot open as an archive)
# died here with EXTRACT_FAILED — a 5.9.9 regression that broke the
# "picked file installs directly" path. Raw inputs skip straight to
# candidate selection below, where the direct-pick branch takes them.
case "$INPUT" in
    *.7z|*.zip|*.xz|*.gz|*.tgz|*.tar)
        EXTRACTLOG="$STAGE/extract.log"
        echo "INSTALL_PROGRESS: extracting archive" >> "$PROGRESS_FILE" 2>/dev/null || true
        progress_start "extracting archive" "stage" "" "0"
        "$STAGE/7zz" x -y -o"$STAGE" "$INPUT" >"$EXTRACTLOG" 2>&1 || {
            progress_stop
            INPSIZE=$(stat -c %s "$INPUT" 2>/dev/null || echo 0)
            echo "EXTRACT_FAILED: 7zz could not extract $INPUT ($INPSIZE bytes):"
            tail -n 10 "$EXTRACTLOG" 2>/dev/null
            fail "EXTRACT_FAILED: 7zz extraction failed for $INPUT ($INPSIZE bytes; 7zz error above)"
        }
        progress_stop
        echo "INSTALL_PROGRESS: extraction done" >> "$PROGRESS_FILE" 2>/dev/null || true
        ;;
esac

# 5.9.16: protected-subtree filter, shared with the sweep
# whitelist below. The sweep no longer deletes backups, snapshots,
# other slots, guest data or the mounted rootfs — so candidate
# selection must not COUNT them either, or a slot with any backup
# (>100 MB by definition) would now fail every install with
# AMBIGUOUS on files the sweep deliberately kept (proven by VM
# test: with backups + data present, selection counted them as
# candidates). Filter helper: drop any path under a protected
# subtree from a find listing.
filter_protected() {
    grep -v -F "$STAGE/backups/" | grep -v -F "$STAGE/snapshots/" | grep -v -F "$STAGE/slots/" | grep -v -F "$STAGE/data/" | grep -v -F "$STAGE/rootfs/"
}
CAND=""
for n in system.img system_a.img system_b.img; do
    CAND=$(find "$STAGE" -maxdepth 3 -name "$n" 2>/dev/null | filter_protected | head -n 1)
    [ -n "$CAND" ] && break
done
if [ -z "$CAND" ]; then
    CAND=$(find "$STAGE" -maxdepth 3 -name '*system*.img' ! -name 'system_ext*' 2>/dev/null | filter_protected | head -n 1)
fi
# 5.9.8: a release-named image (e.g. LineageOS-23.2-...-GSI.img) matches
# neither pattern above, so any *.img at all now beats the large-file
# fallback. system_ext is excluded here too — it is not a system image.
if [ -z "$CAND" ]; then
    IMGS=$(find "$STAGE" -maxdepth 3 -type f -name '*.img' ! -name 'system_ext*' 2>/dev/null | filter_protected | grep -v -F "$OUT" | grep -v -F "$INPUT")
    NIMG=$(printf '%s' "$IMGS" | grep -c . || true)
    if [ "$NIMG" = "1" ]; then
        CAND="$IMGS"
    elif [ "$NIMG" -gt "1" ]; then
        # Largest .img wins: a GSI system image dwarfs any other .img in
        # the archive. (stat+sort pipeline: POSIX sh has no arrays and
        # loop variables do not survive a pipeline subshell.)
        LARGEST=$(printf '%s\n' "$IMGS" | while IFS= read -r img; do
            [ -n "$img" ] || continue
            SZ=$(stat -c %s "$img" 2>/dev/null || echo 0)
            echo "$SZ $img"
        done | sort -nr | head -n 1)
        CAND=$(printf '%s' "$LARGEST" | sed 's/^[0-9]* //')
        LSIZE=$(printf '%s' "$LARGEST" | sed 's/ .*//')
        echo "MULTIPLE_IMAGES: picked largest .img ($LSIZE bytes) among $NIMG candidates: $CAND"
    fi
fi
if [ -z "$CAND" ]; then
    # 5.9.16: same protected-subtree filter as the .img search
    # above — a backup or guest-data file must never be picked as
    # the install candidate either.
    BIG=$(find "$STAGE" -maxdepth 3 -type f -size +100M ! -name '*.img' 2>/dev/null | filter_protected | grep -v -F "$OUT" | grep -v -F "$INPUT")
    N=$(printf '%s' "$BIG" | grep -c . || true)
    if [ "$N" = "1" ]; then
        CAND="$BIG"
    elif [ "$N" -gt "1" ]; then
        # 5.9.8: AMBIGUOUS must be diagnosable — print every candidate
        # with its size before failing, so the next report names files.
        echo "AMBIGUOUS_CANDIDATES: $N large non-.img files, none named system.img:"
        printf '%s\n' "$BIG" | while IFS= read -r f; do
            [ -n "$f" ] || continue
            SZ=$(stat -c %s "$f" 2>/dev/null || echo 0)
            echo "  $f ($SZ bytes)"
        done
        fail "AMBIGUOUS: multiple large extracted files and none is named system.img (candidate list above)"
    fi
fi
if [ -z "$CAND" ]; then
    case "$INPUT" in
        *.7z|*.zip|*.xz|*.gz|*.tgz|*.tar|*.zst|*.zstd|*.lz4|*.br) ;;
        *)
            # 5.9.5-SCRIPTS: a directly-picked sparse file is small by
            # design (sparse compression), so the >100 MB raw-input
            # rule below would never select it. Select it on sparse
            # magic instead; conversion + fs checks below still gate it.
            INMAGIC=$(od -An -tx1 -N4 "$INPUT" 2>/dev/null | tr -d ' \n')
            if [ "$INMAGIC" = "3aff26ed" ]; then
                CAND="$INPUT"
            else
                SIZE=$(stat -c %s "$INPUT" 2>/dev/null || echo 0)
                # 5.9.10: no shell integer test on byte sizes — a
                # >2 GiB local file wraps negative and the old
                # -gt 100000000 test wrongly rejected it. -s proves
                # non-empty; the ~100 MB threshold is an MB count
                # (small, overflow-proof) computed via awk.
                SIZE_MB=$(awk -v s="$SIZE" 'BEGIN{printf "%d", s/1048576}' 2>/dev/null || echo 0)
                case "$SIZE_MB" in ''|*[!0-9]*) SIZE_MB=0 ;; esac
                [ -s "$INPUT" ] && [ "$SIZE_MB" -gt 95 ] && CAND="$INPUT"
            fi
            ;;
    esac
fi
[ -n "$CAND" ] || fail "NO_IMAGE_PRODUCED"

case "$CAND" in
    *super.img) fail "SUPER_IMAGE: this is a super image (LP container), not a system image — convert it first, then install the result: on a PC run 'lpunpack super.img <outdir>' (lpunpack ships with Android build tools / otatools) and install the system.img inside that folder; do not install super.img directly" ;;
esac

MAGIC0=$(od -An -tx1 -N4 "$CAND" 2>/dev/null | tr -d ' \n')
# 5.9.5-SCRIPTS-START: sparse -> raw conversion (simg2img, bundled).
if [ "$MAGIC0" = "3aff26ed" ]; then
    SIMG="$STAGE/simg2img"
    # 5.9.6: a named slot's install step used to copy only install_image.sh
    # and 7zz, leaving simg2img behind — so a sparse local image failed here
    # even though the converter is bundled. Fall back to the Default stage
    # copy (the Java install step now also copies it into named slots).
    [ -x "$SIMG" ] || SIMG="/data/local/tmp/lineage_stage/simg2img"
    [ -f "$SIMG" ] && chmod 755 "$SIMG" 2>/dev/null || true
    [ -x "$SIMG" ] || fail "SPARSE_IMAGE: sparse GSIs need simg2img conversion, which is not available (simg2img missing from stage and from /data/local/tmp/lineage_stage)"
    BLK_SZ=$(dd if="$CAND" bs=1 skip=12 count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
    TOTAL_BLKS=$(dd if="$CAND" bs=1 skip=16 count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
    CONVERTED_FILE="$OUT.converted"
    rm -f "$CONVERTED_FILE" 2>/dev/null
    # 5.9.16: periodic progress markers while simg2img runs (see
    # progress_start above; the app polls install_progress.log).
    _EXP_MB="$(awk -v b="$BLK_SZ" -v t="$TOTAL_BLKS" 'BEGIN{printf "%d", b*t/1048576}' 2>/dev/null || echo 0)"
    echo "INSTALL_PROGRESS: converting sparse image (~$_EXP_MB MB expected)" >> "$PROGRESS_FILE" 2>/dev/null || true
    progress_start "converting sparse image" "file" "$CONVERTED_FILE" "$_EXP_MB"
    "$SIMG" "$CAND" "$CONVERTED_FILE" >/dev/null 2>&1 || { progress_stop; fail "SPARSE_CONVERT_FAILED: simg2img failed on $CAND"; }
    progress_stop
    echo "INSTALL_PROGRESS: sparse conversion done" >> "$PROGRESS_FILE" 2>/dev/null || true
    [ -f "$CONVERTED_FILE" ] || fail "SPARSE_CONVERT_FAILED: simg2img produced no output"
    CONV_SIZE=$(stat -c %s "$CONVERTED_FILE" 2>/dev/null || echo 0)
    case "$BLK_SZ" in ''|*[!0-9]*) fail "SPARSE_CONVERT_FAILED: cannot parse sparse header blk_sz" ;; esac
    case "$TOTAL_BLKS" in ''|*[!0-9]*) fail "SPARSE_CONVERT_FAILED: cannot parse sparse header total_blks" ;; esac
    # 5.9.10: BLK_SZ*TOTAL_BLKS overflows 32-bit $(( )) for any
    # sparse image over 2 GiB, so the old string compare against a
    # wrapped product falsely failed conversion. Compare in MB via
    # awk doubles instead — dividing both sides by 2^20 is exact,
    # so this comparison is exact, not approximate.
    awk -v b="$BLK_SZ" -v t="$TOTAL_BLKS" -v c="$CONV_SIZE" 'BEGIN{exit !(c/1048576 == b*t/1048576)}' 2>/dev/null || fail "SPARSE_CONVERT_FAILED: output size $CONV_SIZE bytes != sparse header total_blks $TOTAL_BLKS * blk_sz $BLK_SZ"
    CAND="$CONVERTED_FILE"
    echo "SPARSE_CONVERTED: $CONV_SIZE bytes (total_blks $TOTAL_BLKS * blk_sz $BLK_SZ) -> $CONVERTED_FILE"
fi
# 5.9.5-SCRIPTS-END

MAGIC_EXT=$(dd if="$CAND" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
MAGIC_EROFS=$(dd if="$CAND" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
FSTYPE="unknown"
[ "$MAGIC_EXT" = "53ef" ] && FSTYPE="ext4"
[ "$MAGIC_EROFS" = "e2e1f5e0" ] && FSTYPE="erofs"
[ "$FSTYPE" = "unknown" ] && fail "UNKNOWN_FORMAT: not an ext4 or EROFS system image — if this file is a super.img, unpack it first with 'lpunpack super.img <outdir>' and install the system.img inside; if it is compressed (.zst/.lz4/.br), decompress it first ('zstd -d' / 'lz4 -d' / 'brotli -d') and install the result; if it is a ROM zip, it needs an sdat2img-style conversion this installer does not do — install a raw system image instead"

SIZE=$(stat -c %s "$CAND" 2>/dev/null || echo 0)
case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
# 5.9.10: the old test here, [ "$SIZE" -le 0 ], WAS the 5.9.9
# on-device bug — the phone's 32-bit test wraps any size over 2 GiB
# to a negative number, so the valid 3446353920-byte GAPPS image
# (and the 2733260800-byte VANILLA image) failed as "empty" despite
# valid ext4 magic and a correct stat size. test -s evaluates size
# in C via stat and is correct at any size; SIZE stays a string
# used only for logging below.
if [ ! -s "$CAND" ]; then
    echo "CANDIDATE_EMPTY_DIAG: candidate=$CAND"
    ls -l "$CAND" 2>&1 || echo "CANDIDATE_EMPTY_DIAG: ls/stat failed for $CAND"
    echo "CANDIDATE_EMPTY_DIAG: magic ext4=$MAGIC_EXT erofs=$MAGIC_EROFS fstype=$FSTYPE"
    fail "CANDIDATE_EMPTY: candidate $CAND statted at $SIZE bytes (magic ext4=$MAGIC_EXT erofs=$MAGIC_EROFS)"
fi
# 5.9.16: pre-install fit check (diagnostic only — it NEVER fails
# the install). The candidate is loop-mounted read-only, its
# build.prop SDK/release read with keyed greps, and compared with
# the host vendor SDK from /system/build.prop. A guest older than
# the vendor prints FIT_WARNING before the install completes, so
# the skew is flagged before the first failed boot instead of
# diagnosed after three. SDKs are small ints, so plain shell tests
# here are safe (the 32-bit rule covers raw byte sizes only). If
# the mount fails (EROFS support, loop busy), the check is skipped
# honestly and the install proceeds — boot will tell.
FITMNT="$STAGE/.fitcheck_mnt"
rm -rf "$FITMNT" 2>/dev/null; mkdir -p "$FITMNT" 2>/dev/null || true
if mount -t "$FSTYPE" -o ro,loop "$CAND" "$FITMNT" 2>/dev/null; then
    _GSDK="$(grep -m1 '^ro.build.version.sdk=' "$FITMNT/system/build.prop" 2>/dev/null | cut -d= -f2-)"
    _GREL="$(grep -m1 '^ro.build.version.release=' "$FITMNT/system/build.prop" 2>/dev/null | cut -d= -f2-)"
    _HSDK="$(grep -m1 '^ro.build.version.sdk=' /system/build.prop 2>/dev/null | cut -d= -f2-)"
    case "$_GSDK" in ''|*[!0-9]*) echo "FIT_CHECK_SKIPPED: guest build.prop has no readable ro.build.version.sdk" ;;
        *) case "$_HSDK" in ''|*[!0-9]*) echo "FIT_CHECK_SKIPPED: host build.prop has no readable ro.build.version.sdk" ;;
            *) if [ "$_GSDK" -lt "$_HSDK" ]; then echo "FIT_WARNING: this guest is older than your vendor (guest Android ${_GREL} SDK $_GSDK vs host vendor SDK $_HSDK) — expect HAL trouble (radio/camera/audio may misbehave); it may still boot, but do not be surprised"; else echo "FIT_OK: guest SDK $_GSDK vs host vendor SDK $_HSDK"; fi ;;
            esac ;;
    esac
    umount "$FITMNT" 2>/dev/null || true
else
    echo "FIT_CHECK_SKIPPED: candidate could not be loop-mounted read-only for a build.prop fit check (install proceeds; boot will tell)"
fi
rmdir "$FITMNT" 2>/dev/null || true
AVAIL_KB=$(df "$STAGE" 2>/dev/null | tail -n 1 | awk '{print $4}')
if [ -n "$AVAIL_KB" ]; then
    case "$AVAIL_KB" in
        ''|*[!0-9]*) ;;
        # 5.9.10: AVAIL_KB*1024 overflows for any phone with >2 GB
        # free, and SIZE+SIZE/10 overflows for any image >~1.9 GiB
        # — both sides of the old test were broken. Compare in MB
        # via awk doubles: free MB < size MB * 1.1 means no space.
        *) awk -v a="$AVAIL_KB" -v s="$SIZE" 'BEGIN{exit !(a/1024 < s/1048576*1.1)}' 2>/dev/null && fail "NO_SPACE: not enough free space for this GSI" ;;
    esac
fi

TMP="$OUT.new"
rm -f "$TMP" 2>/dev/null
if [ "$MOVE" = "1" ] && [ "$CAND" = "$INPUT" ]; then
    mv -f "$CAND" "$TMP" 2>/dev/null || fail "WRITE_FAILED"
else
    cp -f "$CAND" "$TMP" 2>/dev/null || fail "WRITE_FAILED"
fi
GOT=$(stat -c %s "$TMP" 2>/dev/null || echo 0)
[ "$GOT" = "$SIZE" ] || { rm -f "$TMP" 2>/dev/null; fail "WRITE_FAILED: truncated copy"; }
chmod 644 "$TMP" 2>/dev/null
mv -f "$TMP" "$OUT" || fail "RENAME_FAILED"
# 5.9.5-SCRIPTS-START: converted temp is no longer needed once the
# verified raw image is installed (fail() above also cleans it).
[ -n "$CONVERTED_FILE" ] && rm -f "$CONVERTED_FILE" 2>/dev/null || true
CONVERTED_FILE=""
# 5.9.5-SCRIPTS-END
# 5.9.10: SIZE/1048576 in $(( )) wraps to a negative MB display
# for >2 GiB images; MB via awk instead.
IMAGE_MB=$(awk -v s="$SIZE" 'BEGIN{printf "%d", s/1048576}' 2>/dev/null || echo 0)
echo "INSTALL_PROGRESS: done" >> "$PROGRESS_FILE" 2>/dev/null || true
echo "IMAGE_OK: $FSTYPE $IMAGE_MB MB -> $OUT"
exit 0

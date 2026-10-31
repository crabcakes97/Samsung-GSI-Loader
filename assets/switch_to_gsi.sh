#!/system/bin/sh
# GSI Loader Samsung Userspace Takeover Orchestrator
# Slot support (5.9.3): $1 is the stage dir. Default (no arg) is the
# historical single install, so old callers are unaffected. A named slot
# must live directly under $DEFAULT/slots/ with a clean name — anything
# else (absolute escapes, traversal, nested paths) is rejected before
# any mount, bind, or file operation happens.
DEFAULT_STAGE="/data/local/tmp/lineage_stage"
STAGE="${1:-$DEFAULT_STAGE}"
case "$STAGE" in
    "$DEFAULT_STAGE") ;;
    "$DEFAULT_STAGE"/slots/*)
        SLOTNAME="${STAGE##*/slots/}"
        case "$SLOTNAME" in
            ''|*/*|*[!A-Za-z0-9_-]*)
                echo "!!! INVALID STAGE: $STAGE"; exit 1 ;;
        esac
        ;;
    *) echo "!!! INVALID STAGE: $STAGE"; exit 1 ;;
esac
# 5.9.5-SCRIPTS-START: stage containment + already-running guard +
# host-untouched preflight (guards.sh / preflight_host.sh). A missing
# guards.sh means an old extraction: warn and continue with the legacy
# validation above rather than breaking boot on an old install.
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
    gsi_validate_stage "$STAGE" || { echo "!!! INVALID STAGE (guards): $STAGE"; exit 1; }
    if gsi_guest_running "$STAGE"; then
        echo "!!! SLOT_RUNNING: guest for $STAGE is already running — return to One UI first"
        exit 1
    fi
else
    echo "WARNING: guards.sh not found in $STAGE (old extraction); continuing with legacy checks"
fi
if [ -f "$STAGE/preflight_host.sh" ]; then
    PREFLIGHT_OUT=$(/system/bin/sh "$STAGE/preflight_host.sh" 2>&1)
    echo "Preflight: $PREFLIGHT_OUT"
    case "$PREFLIGHT_OUT" in
        *outside\ staging*)
            echo "!!! PREFLIGHT hard failure (guest rootfs / staging outside staging root) — aborting takeover"
            exit 1
            ;;
        PREFLIGHT_FAIL*)
            echo "WARNING: preflight failed (host partitions not read-only or mounts missing) — continuing, guest boot may be affected"
            ;;
    esac
fi
# 6.0 (P11): One UI host-layout backup BEFORE the takeover stops
# anything. Launcher databases/shared_prefs, appwidgets, QS tiles
# and the launcher UID go to /data/local/tmp/gsi_host_backup (a
# separate dir from the legacy lineage_backups databases restore);
# return_to_oneui.sh restores the extras from it. Best-effort and
# never fatal: a failed backup must not block the guest boot.
if [ -f "$STAGE/backup_host.sh" ]; then
    /system/bin/sh "$STAGE/backup_host.sh" 2>&1 || echo "HOST_BACKUP_WARN: backup_host.sh failed (continuing; return will restore databases only)"
else
    echo "HOST_BACKUP_WARN: backup_host.sh missing from $STAGE (continuing; return will restore databases only)"
fi
# 5.9.5-SCRIPTS-END
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
RP=$(which resetprop 2>/dev/null || echo "/data/adb/ksu/bin/resetprop")
[ -x "$RP" ] || RP=$(find /data/adb /system -name resetprop 2>/dev/null | head -n 1)

export BB
export RP
export STAGE

set_prop() {
    if [ -n "$RP" ] && [ -x "$RP" ]; then
        "$RP" "$1" "$2" 2>/dev/null || true
    else
        setprop "$1" "$2" 2>/dev/null || true
    fi
}

# --- PERSIST SNAPSHOT (6.2 P3, SESSION-SCOPED) ---------------------------
# Mechanism re-implemented from OneOS (fahadalijaved): snapshot all
# persist.* props BEFORE anything below (or the guest) can change them,
# so return_to_oneui.sh can restore One UI's exact values. The snapshot
# is also the hard-reset recovery: if a previous session crashed, its
# snapshot file is still here and is restored FIRST (below), before a
# fresh snapshot is taken — otherwise the crashed session's values
# would be captured as "originals".
# Gate (OneOS's rule): resetprop must prove it can WRITE and DELETE a
# persist prop, or the switch is REFUSED loudly — a session whose
# persist changes cannot be undone must never start. The probe uses a
# scratch prop in our own namespace and deletes it again; spellings
# are tried in order (-p first, then plain; --delete, then -d) because
# Magisk and KernelSU resetprop builds differ, and the winning
# spelling is recorded for return_to_oneui.sh to reuse.
PERSIST_SNAP_FILE="/data/local/tmp/gsi_persist_snapshot"
PERSIST_SPELL_FILE="/data/local/tmp/gsi_persist_spelling"
PERSIST_PROBE_PROP="persist.gsi_loader_probe"
_RP_SETFLAGS=""
_RP_DELFLAGS=""
_RP_DELPERSIST=""
gsi_resetprop_probe() {
    # $1 = setflags ("-p" or ""), $2 = delflags ("--delete" or "-d"),
    # $3 = delpersist ("-p" or ""). Returns 0 if a full write/read/delete
    # cycle on the scratch prop works with this spelling.
    _pset="$1"; _pdel="$2"; _pdelp="$3"
    if [ -n "$_pset" ]; then
        "$RP" $_pset "$PERSIST_PROBE_PROP" 1 2>/dev/null || return 1
    else
        "$RP" "$PERSIST_PROBE_PROP" 1 2>/dev/null || return 1
    fi
    [ "$(getprop "$PERSIST_PROBE_PROP" 2>/dev/null)" = "1" ] || return 1
    if [ -n "$_pdelp" ]; then
        "$RP" $_pdelp "$_pdel" "$PERSIST_PROBE_PROP" 2>/dev/null || return 1
    else
        "$RP" "$_pdel" "$PERSIST_PROBE_PROP" 2>/dev/null || return 1
    fi
    [ -z "$(getprop "$PERSIST_PROBE_PROP" 2>/dev/null)" ] || return 1
    return 0
}
gsi_persist_restore_file() {
    # $1 = snapshot file. Restores every name=value line via resetprop
    # (proven spelling), then deletes persist.vendor.softdog ONLY if it
    # was set by a session (absent from the snapshot). Never aborts the
    # caller on a single bad line.
    _snap="$1"
    _restored=0; _failed=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            ''|'#'*) continue ;;
        esac
        _pname="${_line%%=*}"; _pval="${_line#*=}"
        [ -n "$_pname" ] || continue
        if [ -n "$_RP_SETFLAGS" ]; then
            "$RP" $_RP_SETFLAGS "$_pname" "$_pval" 2>/dev/null || { _failed=$((_failed + 1)); continue; }
        else
            "$RP" "$_pname" "$_pval" 2>/dev/null || { _failed=$((_failed + 1)); continue; }
        fi
        _restored=$((_restored + 1))
    done < "$_snap"
    echo "PERSIST_RESTORE: restored $_restored props from $_snap, $_failed failures"
    if ! grep -q "^persist\.vendor\.softdog=" "$_snap" 2>/dev/null; then
        if [ -n "$(getprop persist.vendor.softdog 2>/dev/null)" ]; then
            if [ -n "$_RP_DELPERSIST" ]; then
                "$RP" $_RP_DELPERSIST "$_RP_DELFLAGS" persist.vendor.softdog 2>/dev/null || true
            else
                "$RP" "$_RP_DELFLAGS" persist.vendor.softdog 2>/dev/null || true
            fi
            if [ -z "$(getprop persist.vendor.softdog 2>/dev/null)" ]; then
                echo "PERSIST_RESTORE: persist.vendor.softdog deleted (set by a session, absent from snapshot)"
            else
                echo "PERSIST_RESTORE_WARNING: could not delete persist.vendor.softdog (resetprop delete failed; value stays until the next switch or a manual resetprop --delete)"
            fi
        fi
    fi
    return 0
}
if [ -z "$RP" ] || [ ! -x "$RP" ]; then
    echo "!!! PERSIST_SNAPSHOT_REFUSED: no usable resetprop (RP='$RP') — One UI's persist.* props could not be saved and restored; refusing the switch"
    exit 1
fi
if gsi_resetprop_probe "-p" "--delete" "-p"; then
    _RP_SETFLAGS="-p"; _RP_DELFLAGS="--delete"; _RP_DELPERSIST="-p"
elif gsi_resetprop_probe "" "--delete" ""; then
    _RP_SETFLAGS=""; _RP_DELFLAGS="--delete"; _RP_DELPERSIST=""
elif gsi_resetprop_probe "" "-d" ""; then
    _RP_SETFLAGS=""; _RP_DELFLAGS="-d"; _RP_DELPERSIST=""
elif gsi_resetprop_probe "-p" "-d" "-p"; then
    _RP_SETFLAGS="-p"; _RP_DELFLAGS="-d"; _RP_DELPERSIST="-p"
else
    # Last-ditch cleanup of the scratch prop, then refuse loudly.
    "$RP" --delete "$PERSIST_PROBE_PROP" 2>/dev/null || true
    "$RP" -d "$PERSIST_PROBE_PROP" 2>/dev/null || true
    echo "!!! PERSIST_SNAPSHOT_REFUSED: resetprop cannot write+delete persist props on this phone — One UI's props could not be restored on return; refusing the switch"
    exit 1
fi
echo "PERSIST_SNAPSHOT: resetprop probe passed (setflags='$_RP_SETFLAGS' delflags='$_RP_DELFLAGS')"
printf '%s|%s|%s\n' "$_RP_SETFLAGS" "$_RP_DELFLAGS" "$_RP_DELPERSIST" > "$PERSIST_SPELL_FILE" 2>/dev/null || true
# Hard-reset recovery: a snapshot left by a crashed session is restored
# now, before the fresh snapshot, so crashed-session values are never
# captured as originals. A live guest is already refused above
# (guards.sh), so no running session can own this file here.
if [ -f "$PERSIST_SNAP_FILE" ]; then
    echo "PERSIST_RECOVERY: stale snapshot from a previous session found ($PERSIST_SNAP_FILE) — restoring it before taking a fresh snapshot (hard-reset recovery)"
    gsi_persist_restore_file "$PERSIST_SNAP_FILE"
fi
if ! getprop 2>/dev/null | sed -n 's/^\[\(persist\.[^]]*\)\]: \[\(.*\)\]$/\1=\2/p' > "$PERSIST_SNAP_FILE.tmp" 2>/dev/null; then
    echo "!!! PERSIST_SNAPSHOT_REFUSED: could not enumerate persist.* props — refusing the switch"
    exit 1
fi
# A failed getprop leaves an empty file while sed still exits 0 — never
# trust an empty (or near-empty) snapshot: it would restore nothing and
# could delete a legit persist.vendor.softdog. Any real phone has
# dozens of persist.* props; fewer than 5 means enumeration broke.
_PERSIST_SNAP_COUNT="$(grep -c . "$PERSIST_SNAP_FILE.tmp" 2>/dev/null || true)"
case "$_PERSIST_SNAP_COUNT" in ''|*[!0-9]*) _PERSIST_SNAP_COUNT=0 ;; esac
if [ "$_PERSIST_SNAP_COUNT" -lt 5 ]; then
    echo "!!! PERSIST_SNAPSHOT_REFUSED: only $_PERSIST_SNAP_COUNT persist.* props enumerated (expected dozens) — refusing the switch"
    rm -f "$PERSIST_SNAP_FILE.tmp" 2>/dev/null || true
    exit 1
fi
# Atomic publish: the snapshot is only trusted once fully written.
if ! mv -f "$PERSIST_SNAP_FILE.tmp" "$PERSIST_SNAP_FILE" 2>/dev/null; then
    echo "!!! PERSIST_SNAPSHOT_REFUSED: could not publish $PERSIST_SNAP_FILE — refusing the switch"
    exit 1
fi
_PERSIST_SNAP_COUNT="$(grep -c . "$PERSIST_SNAP_FILE" 2>/dev/null || true)"
case "$_PERSIST_SNAP_COUNT" in ''|*[!0-9]*) _PERSIST_SNAP_COUNT=0 ;; esac
echo "PERSIST_SNAPSHOT: $_PERSIST_SNAP_COUNT persist.* props saved to $PERSIST_SNAP_FILE (restored by return_to_oneui.sh)"

BACKUP_DIR="/data/local/tmp/lineage_backups"

echo "=== GSI TAKEOVER STARTING ==="

# Put SELinux in permissive mode for the duration of the takeover. The guest
# userspace is a foreign, unlabelled-for-this-policy userspace: its
# system_server runs as u:r:system_server:s0 against Samsung's policy, and MAC
# denials there surface as confusing EACCES/ENOENT deep inside system_server
# (e.g. settings.db "doesn't exist", users/0.xml EACCES). master_prepare.sh
# relabels the staged /data properly, but permissive is the safety net that
# keeps the rest of the guest boot from tripping over labels we cannot predict.
# return_to_oneui.sh restores enforcing.
setenforce 0 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"

# --- IMS / SMS REGISTRATION GATE -----------------------------------------
# The guest has no ImsService of its own, so the modem's IMS registration is
# owned by One UI's imsd and survives the takeover. That registration is what
# makes SMS behave: with it, T-Mobile delivers inbound SMS promptly (Samsung's
# RIL hands SMSoIP messages to the framework as normal SMS) and the modem
# accepts mobile-originated SMS. Without it, voice sits OUT_OF_SERVICE, sends
# fail with RESULT_ERROR_NO_SERVICE and inbound codes fall back to the SMSC
# retry schedule, arriving 20-40 minutes late - and every radio nudge then
# appears to "magically" deliver them.
# So: make sure imsd is up, and give the modem a moment to (re)register before
# the pivot. Never stop imsd afterwards; killing it was what degraded SMS.
if ! pidof imsd >/dev/null 2>&1; then
    setprop ctl.start imsd 2>/dev/null || true
fi
ims_i=0
ims_st=1
while [ "$ims_i" -lt 45 ]; do
    if dumpsys telephony.registry 2>/dev/null | grep -q 'mVoiceRegState=0'; then
        ims_st=0
        break
    fi
    ims_i=$((ims_i + 1))
    sleep 2
    # 5.9.11: progress echo so the app's boot log streaming has movement
    # to show during this gate (up to 90s, previously silent — the
    # "Boot feels hung" report). Gate semantics unchanged: same 45
    # iterations, same 2s sleep, same break condition.
    if [ $((ims_i % 5)) -eq 0 ]; then
        echo "IMS gate: waiting for voice registration… $((ims_i * 2))s elapsed (max 90s)"
    fi
done
echo "IMS gate: voiceRegState=$ims_st after $((ims_i * 2))s, imsd=${ims_pid:-$(pidof imsd)}"

# --- ADB WATCHDOG ---------------------------------------------------------
# adb is the only way into the phone while the guest is up (until wifi is
# configured), and the host adbd occasionally dies or loses the adb function
# when the container's system_server touches the USB configuration. init does
# not reliably restart it, which is the "adb randomly stopped working" symptom.
# Keep it supervised from the host namespace for the whole session; the watchdog
# is stopped again by return_to_oneui.sh.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "adb_watchdog.sh"; then
    cat > /data/local/tmp/adb_watchdog.sh <<'ADBW'
#!/system/bin/sh
# Watchdog for the host adbd, which is the only way into the phone while the guest
# is up. Two failure modes are handled:
#   1. adbd simply died -> ask init to start it again.
#   2. adbd is alive but the USB gadget lost the adb function. The guest's own
#      UsbService rewrites sys.usb.config during boot, and a plain setprop is a
#      no-op in that state, so the gadget has to be re-applied by toggling it.
LOG=/data/local/tmp/adb_watchdog.log
last_toggle=0
while true; do
    sleep 10
    st=$(getprop init.svc.adbd)
    usb=$(getprop sys.usb.state)
    cfg=$(getprop sys.usb.config)
    if [ "$st" != "running" ]; then
        setprop ctl.start adbd 2>/dev/null
        echo "$(date) restarted adbd (was: $st, usb.state=$usb, usb.config=$cfg)" >> "$LOG"
    fi
    case "$cfg" in
        *adb*) ;;
        *)
            setprop sys.usb.config "$cfg,adb" 2>/dev/null
            echo "$(date) added adb to usb.config (was: $cfg)" >> "$LOG"
            ;;
    esac
    case "$usb" in
        *adb*) ;;
        "")
            ;;
        *)
            now=$(date +%s 2>/dev/null || echo 0)
            if [ $((now - last_toggle)) -gt 300 ]; then
                last_toggle=$now
                echo "$(date) gadget lost adb, toggling (state: $usb, config: $cfg)" >> "$LOG"
                setprop sys.usb.config none 2>/dev/null
                sleep 1
                setprop sys.usb.config rndis,adb 2>/dev/null
                sleep 2
                setprop ctl.start adbd 2>/dev/null
            fi
            ;;
    esac
done
ADBW
    chmod 755 /data/local/tmp/adb_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "adbd watchdog started (log: /data/local/tmp/adb_watchdog.log)"
fi

# --- IMS KEEPALIVE --------------------------------------------------------
# imsd is the daemon holding the modem's IMS registration (see the IMS gate
# above). init does not always bring it back if it dies, and a dead imsd means
# SMS quietly degrades to "arrives whenever the SMSC next retries", so keep it
# supervised for the whole guest session.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "ims_watchdog.sh"; then
    cat > /data/local/tmp/ims_watchdog.sh <<'IMSW'
#!/system/bin/sh
LOG=/data/local/tmp/ims_watchdog.log
while true; do
    sleep 60
    if ! pidof imsd >/dev/null 2>&1; then
        setprop ctl.start imsd 2>/dev/null
        echo "$(date) restarted imsd (was missing)" >> "$LOG"
    fi
done
IMSW
    chmod 755 /data/local/tmp/ims_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "imsd keepalive started (log: /data/local/tmp/ims_watchdog.log)"
fi

# Set permissive privapp permissions to avoid Signature|privileged fatal exceptions
set_prop ro.control_privapp_permissions log

# --- ONEUI PROTECTION & RESCUEPARTY DISABLE ---
echo "=== [1/6] Protecting OneUI Home Screen and Disabling RescueParty ==="
set_prop persist.sys.disable_rescue true
set_prop sys.rescue_boot_count 0
# 5.9.13: read back the RescueParty disable so a failed boot's log shows
# whether the guest's crash-escalation reboot path was actually off.
# If system_server crash-loops and RescueParty is live, it reboots the
# phone after several crashes — which matches an EROFS boot that runs
# for minutes then restarts. A confirmed disable rules that path out.
echo "RescueParty: persist.sys.disable_rescue=$(getprop persist.sys.disable_rescue 2>/dev/null || echo unknown), sys.rescue_boot_count=$(getprop sys.rescue_boot_count 2>/dev/null || echo unknown)"
mkdir -p "$BACKUP_DIR"
if [ -d "/data/user/0/com.sec.android.app.launcher/databases" ]; then
    cp -a /data/user/0/com.sec.android.app.launcher/databases/* "$BACKUP_DIR/" 2>/dev/null || true
    echo "One UI Home databases snapshotted to $BACKUP_DIR"
fi

# --- AUDIO LOW LATENCY TUNING ---
# Deep buffer must stay OFF. Tested live: with audio.deep_buffer.media=true the
# deep-buffer output opens but never consumes, and an AudioTrack write blocks
# forever (app_process hung in futex_wait). The 20 ms normal path is the one
# that actually works; a streamed tone on it is clean (0 underruns, 0 late
# writes). Offload stays off: no working vendor DSP session in the container.
echo "=== [2/6] Configuring Low-Latency Audio ==="
set_prop audio.offload.disable 1
set_prop audio.deep_buffer.media false
set_prop audio.offload.video false
set_prop vendor.audio.offload.track.enable false

# --- NETWORK BPF FIREWALL & DNS BYPASS ---
echo "=== [3/6] Configuring Network BPF Filters ==="
bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_configuration_map key hex 00 00 00 00 value hex 00 00 00 00 2>/dev/null || true
chmod 666 /dev/socket/dnsproxyd 2>/dev/null || true

# --- VERIFY STAGING ENVIRONMENT ---
echo "=== [4/6] Verifying Staging Environment ==="
if [ ! -f "$STAGE/system.raw" ]; then
    echo "ERROR: GSI system image ($STAGE/system.raw) not found!"
    echo "Please install a GSI in the app first."
    exit 1
fi

# Ensure all scripts and engine binaries exist in $STAGE
mkdir -p "$STAGE/data"
APP_FILES="/data/user/0/com.cronch.gsiloader/files"
if [ -d "$APP_FILES" ]; then
    cp -f "$APP_FILES"/* "$STAGE/" 2>/dev/null || true
fi
chmod 755 "$STAGE"/*.sh "$STAGE/zygote_exec" 2>/dev/null || true

# --- MOUNT PREPARATION ---
echo "=== [5/6] Executing Mount Hierarchy Preparation ==="
/system/bin/sh "$STAGE/master_prepare.sh" "$STAGE"
PREP_RET=$?
if [ $PREP_RET -ne 0 ]; then
    echo "ERROR: master_prepare.sh failed (code $PREP_RET)!"
    exit 1
fi

# --- GSI KERNEL WATCHDOG TIMEOUT CONTROL (5.9.18, SESSION-SCOPED) -------
# 6.2 (O1): this block MOVED to before the [6/6] kill spree below. In
# 5.9.18-6.1 it ran AFTER the zygote stop, leaving the softdog armed
# and unfed during the kill spree and the feeder start. Neutralizing
# first covers the softdog through the whole stop sequence; the
# supervised feeder (started after the kill spree) then takes over
# kicking, and the guest kicker covers the guest side.
# User order: "get rid of the timeout" for GSI sessions. This neutralizes
# the KERNEL watchdog timeout (softdog "Software Watchdog Timer expired",
# ~100 s) for the duration of this guest session ONLY, and
# return_to_oneui.sh restores the original value. It is NOT a permanent
# host-wide disable: a reboot resets every timeout to the driver
# default on its own, and return restores it explicitly.
# The sysfs timeout store invokes the same watchdog_set_timeout as
# WDIOC_SETTIMEOUT (disable if the driver accepts 0, else maximum).
# If the driver rejects timeout control, this logs loudly and the
# session falls back to the supervised feeder + guest kicker above --
# it never pretends the timeout is gone.
# Tradeoff, stated plainly: while the timeout is neutralized, a genuine
# guest/host hang will NOT auto-reboot; force-restart manually
# (power + volume down). The app boot watchdog (boot_watchdog.sh,
# 600 s) is KEPT and is the only auto-return net during sessions.
cat > /data/local/tmp/gsi_watchdog_timeout.sh <<'GSITIMEOUT'
#!/system/bin/sh
# GSI kernel watchdog timeout control (5.9.18, SESSION-SCOPED).
# Verbs: neutralize | restore
# neutralize: record each /sys/class/watchdog/watchdog*/timeout original
#   value to $ORIG_FILE, then try to disable (write 0) else set to max.
# restore: write recorded originals back, verify by read-back.
# All logging goes to stdout; the caller (switch_to_gsi.sh /
# return_to_oneui.sh) redirects it into the takeover/return log.
# The sysfs timeout store invokes the same watchdog_set_timeout as
# WDIOC_SETTIMEOUT (the watchdog core's set path): a rejected store
# (EOPNOTSUPP/EINVAL) means the driver does not support timeout
# control, and the caller falls back to the supervised feeder +
# guest kicker — it must never pretend the timeout is gone.
# Safety invariant: a timeout is NEVER changed before its original
# value is recorded in $ORIG_FILE. If the orig file cannot be written,
# neutralize aborts without touching any node.
# A reboot resets every timeout to the driver default on its own, so
# the session scope holds even if return never runs.
SYSFS_ROOT="${WATCHDOG_SYSFS_ROOT:-/sys/class/watchdog}"
ORIG_FILE="${WATCHDOG_ORIG_FILE:-/data/local/tmp/gsi_watchdog_timeout.orig}"

_neutralize_node() {
    # $1 = node dir. Returns 0 if this node is controlled, 1 otherwise.
    _node="$1"
    _name="${_node##*/}"
    _ident="$(cat "$_node/identity" 2>/dev/null || echo unknown)"
    _orig="$(cat "$_node/timeout" 2>/dev/null || echo "")"
    if [ -z "$_orig" ]; then
        echo "WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE: cannot read timeout for $_name ($_ident)"
        return 1
    fi
    echo "$_name|$_orig" >> "$ORIG_FILE"
    echo "WATCHDOG_TIMEOUT_ORIGINAL: node=$_name identity=$_ident timeout=$_orig"
    # Attempt 1: disable (0). The watchdog API defines 0 as "disable
    # if the driver supports it".
    if echo 0 > "$_node/timeout" 2>/dev/null; then
        _now="$(cat "$_node/timeout" 2>/dev/null || echo "")"
        if [ "$_now" = "0" ]; then
            echo "WATCHDOG_TIMEOUT_DISABLED: node=$_name timeout=0 (was $_orig)"
            return 0
        fi
        # Driver accepted the write but clamped it to something else:
        # undo at once, so a clamped-to-small value can never outlive
        # this block (a 1 s timeout with a 2 s feeder cadence would
        # fire before the next kick).
        echo "$_orig" > "$_node/timeout" 2>/dev/null || true
        _back="$(cat "$_node/timeout" 2>/dev/null || echo "")"
        echo "WATCHDOG_TIMEOUT_DISABLE_CLAMPED: node=$_name wrote 0, read-back=$_back (trying max next)"
    fi
    # Attempt 2: maximum (max_timeout attr if present, else 65535).
    _max="$(cat "$_node/max_timeout" 2>/dev/null || echo "")"
    case "$_max" in
        ''|*[!0-9]*) _max=65535 ;;
    esac
    if echo "$_max" > "$_node/timeout" 2>/dev/null; then
        _now="$(cat "$_node/timeout" 2>/dev/null || echo "")"
        echo "WATCHDOG_TIMEOUT_SET_MAX: node=$_name timeout=$_now (requested $_max, was $_orig)"
        return 0
    fi
    # Neither worked: make sure the original is back, then report.
    echo "$_orig" > "$_node/timeout" 2>/dev/null || true
    echo "WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE: node=$_name identity=$_ident (timeout writes rejected; driver does not support timeout control)"
    return 1
}

neutralize() {
    # NOTE: do NOT use ": > file" here: ":" is a POSIX special builtin
    # and a failed redirect on one kills a non-interactive shell at
    # once (exit 2, no log line). "cat" is an external command, so a
    # failed redirect just returns nonzero and the loud fallback below
    # runs instead.
    if ! cat /dev/null > "$ORIG_FILE" 2>/dev/null; then
        echo "WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE: cannot write orig file $ORIG_FILE (refusing to change any timeout without a recorded original)"
        return 1
    fi
    _found=0
    _controlled=0
    for _node in "$SYSFS_ROOT"/watchdog*; do
        [ -d "$_node" ] || continue
        if [ ! -f "$_node/timeout" ]; then
            echo "WATCHDOG_TIMEOUT_SKIP: node ${_node##*/} has no timeout file"
            _found=1
            continue
        fi
        _found=1
        if _neutralize_node "$_node"; then
            _controlled=1
        fi
    done
    if [ "$_found" -eq 0 ]; then
        echo "WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE: no watchdog nodes found under $SYSFS_ROOT"
        return 1
    fi
    if [ "$_controlled" -eq 0 ]; then
        echo "WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE: no watchdog node accepted a timeout change — supervised feeder + guest kicker remain the protection (do NOT assume the timeout is gone)"
        return 1
    fi
    return 0
}

restore() {
    if [ ! -f "$ORIG_FILE" ]; then
        echo "WATCHDOG_TIMEOUT_RESTORE_SKIPPED: no orig file $ORIG_FILE (timeout was never neutralized this boot, or a previous return already restored it)"
        return 0
    fi
    _fail=0
    while IFS='|' read -r _rn _ro || [ -n "$_rn" ]; do
        [ -n "$_rn" ] || continue
        [ -n "$_ro" ] || continue
        _node="$SYSFS_ROOT/$_rn"
        if [ ! -f "$_node/timeout" ]; then
            echo "WATCHDOG_TIMEOUT_RESTORE_WARNING: node $_rn gone (cannot restore timeout $_ro)"
            _fail=1
            continue
        fi
        if echo "$_ro" > "$_node/timeout" 2>/dev/null; then
            _now="$(cat "$_node/timeout" 2>/dev/null || echo "")"
            if [ "$_now" = "$_ro" ]; then
                echo "WATCHDOG_TIMEOUT_RESTORED: node=$_rn timeout=$_ro"
            else
                echo "WATCHDOG_TIMEOUT_RESTORE_WARNING: node=$_rn wrote $_ro, read-back=$_now (mismatch; a reboot resets the timeout to the driver default)"
                _fail=1
            fi
        else
            echo "WATCHDOG_TIMEOUT_RESTORE_WARNING: node=$_rn could not write original timeout $_ro (a reboot resets the timeout to the driver default)"
            _fail=1
        fi
    done < "$ORIG_FILE"
    if [ "$_fail" -eq 0 ]; then
        rm -f "$ORIG_FILE" 2>/dev/null || true
    fi
    return "$_fail"
}

case "${1:-}" in
    neutralize) neutralize ;;
    restore) restore ;;
    *) echo "Usage: $0 {neutralize|restore}" >&2; exit 2 ;;
esac
GSITIMEOUT
chmod 755 /data/local/tmp/gsi_watchdog_timeout.sh
/system/bin/sh /data/local/tmp/gsi_watchdog_timeout.sh neutralize || echo "WATCHDOG_TIMEOUT_FALLBACK: timeout control unavailable or failed -- supervised feeder + guest kicker start next and remain the protection (see WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE lines above)"

# --- STOP HOST DAEMONS & LAUNCH CONTAINER ---
echo "=== [6/6] Launching GSI Takeover Daemon ==="
pkill -f "while true; do [ \"\$(getprop init.svc.zygote)\"" 2>/dev/null || true
pkill -f "while true; do for p in \\\$(pidof audioserver cameraserver)" 2>/dev/null || true
setprop ctl.stop zygote
setprop ctl.stop surfaceflinger
# audioserver/cameraserver are deliberately left running. The guest shares this
# binder namespace, and its AudioService.<init> -> AudioDeviceBroker.init ->
# AudioSystem::addAudioPortCallback waits on media.audiopolicy with no timeout:
# with no audio policy service registered, system_server's main thread hangs
# (~2 min watchdog stall, boot stuck on the animation). Freezing them with
# kill -STOP is the worst of both worlds - the binder registration survives
# while the process can never answer.
kill -9 $(pidof surfaceflinger) 2>/dev/null || true
kill -9 $(pidof bootanimation) 2>/dev/null || true
kill -9 $(pidof app_process64) 2>/dev/null || true
kill -9 $(pidof zygote_exec) 2>/dev/null || true
kill -9 $(pidof zygote64) 2>/dev/null || true
kill -9 $(pidof system_server) 2>/dev/null || true
# 5.9.11: readiness check instead of a fixed 1s settle: proceed the
# moment all six daemons are dead (usually ~0.1s), but wait up to 2s
# if one is slow to die (SIGKILL can stall on uninterruptible I/O).
# Faster in the common case, and safer than proceeding while a
# daemon is still dying.
_i=0; while [ $_i -lt 20 ]; do
    pidof surfaceflinger >/dev/null 2>&1 || pidof bootanimation >/dev/null 2>&1 || pidof app_process64 >/dev/null 2>&1 || pidof zygote_exec >/dev/null 2>&1 || pidof zygote64 >/dev/null 2>&1 || pidof system_server >/dev/null 2>&1 || break
    _i=$((_i + 1)); sleep 0.1
done

# Stop the HOST media codec stack. The guest's libmedia binds `media.codec` from
# the shared servicemanager, i.e. Samsung's mediaserver - whose IMediaCodecList
# AIDL hash differs from the GSI's. The reply parcel is then parsed as garbage
# ("enforceInterface() expected 'android.gui.IGraphicBufferProducer' but read
# 'android.media.IMediaCodecList'", "AString: ctor got NULL"), which yields a
# codec list with a bogus length, so findCodecForFormat -> codecHandlesFormat
# spins ~2M times inside both system_server and SystemUI, round-tripping to
# mediaserver each iteration. That is the 125% CPU / constant overheating / GB
# of logcat. With no media.codec registered the lookup fails fast and the list
# is empty. Audio is unaffected (audioserver is its own process and is kept).
# mediaserver must stay UP even though the codec list is unusable: apps play
# short sounds with MediaPlayer, and MediaPlayer.setDataSource blocks in
# IMediaDeathNotifier::getMediaPlayerService when "media.player" is missing.
# That is a 5 s main-thread stall -> ANR -> force-close: Messaging died on every
# send because of its "sent" sound (playSentSound), and any app doing the same
# would die too. Keep only the codec processes down, which is what causes the
# spin described above.
setprop ctl.start media 2>/dev/null || true
# 6.0 (P7): wider codec stop list. The software codec and the
# mediaextractor service are further paths to the same codec-list
# spin, and Samsung's software C2 HAL service is the Samsung-side
# C2 path. Qualcomm's vendor-qti C2 service is deliberately NOT
# stopped (this phone is Exynos; see DOES-NOT-APPLY D8).
for svc in media.codec media.swcodec media.metrics mediaextractor samsung-software-media-c2-hal-1-0; do
    setprop ctl.stop $svc 2>/dev/null || true
done
kill -9 $(pidof media.codec) $(pidof mediaswcodec) $(pidof media.metrics) $(pidof mediaextractor) 2>/dev/null || true

# Same handover for wifi. The guest's WifiService binds IWificond (service
# "wifinl80211") and drives the vendor HAL through it. Samsung's wificond is
# still holding the client interface that One UI's (now dead) WifiService
# created, so every startScan() comes back "status: -1" and the framework sees
# "No scan results" - wifi looks broken but only the scanner is wedged. The
# GSI's own wificond starts in master_inner.sh and scans fine against the same
# vendor HAL.
setprop ctl.stop wificond 2>/dev/null || true
kill -9 $(pidof wificond) 2>/dev/null || true
# 5.9.11: readiness check (see above): proceed once wificond is
# dead, max 2s.
_i=0; while [ $_i -lt 20 ]; do pidof wificond >/dev/null 2>&1 || break; _i=$((_i + 1)); sleep 0.1; done

# 5.9.5-SCRIPTS-START: IMS hardening. The takeover above stops ONLY
# host zygote, surfaceflinger, wificond and the media codec stack — it
# must never stop imsd (the modem's IMS registration owner). Verify
# imsd survived the stops; restart it if it died, and log the outcome.
# (The IMS gate + ims_watchdog above are the primary keepalive; this
# is the post-stop verification that the takeover did not kill imsd.)
if pidof imsd >/dev/null 2>&1; then
    echo "IMS_KEEPALIVE_OK: imsd alive after takeover stops (pid $(pidof imsd))"
else
    setprop ctl.start imsd 2>/dev/null || true
    # 5.9.11: readiness check: proceed once imsd is alive, max 2s
    # (was a fixed 1s sleep before the same pidof check below).
    _i=0; while [ $_i -lt 20 ]; do pidof imsd >/dev/null 2>&1 && break; _i=$((_i + 1)); sleep 0.1; done
    if pidof imsd >/dev/null 2>&1; then
        echo "IMS_KEEPALIVE_OK: imsd restarted after takeover stops"
    else
        echo "IMS_KEEPALIVE_FAIL: imsd not running after takeover stops (SMS may degrade)"
    fi
fi
# 5.9.5-SCRIPTS-END

# --- KILL CENSUS (5.9.16) -------------------------------------------------
# One log line naming which kill targets are gone and which survived,
# so "did the takeover kill X?" is answered from takeover_app.log
# instead of by code inspection. Runs AFTER every kill + readiness
# loop above, BEFORE the guest is launched (so no guest process can
# appear in the census yet).
_KILL_GONE=""
_KILL_ALIVE=""
for _svc in surfaceflinger bootanimation app_process64 zygote_exec zygote64 system_server media.codec mediaswcodec media.metrics mediaextractor wificond; do
    if pidof "$_svc" >/dev/null 2>&1; then
        _KILL_ALIVE="$_KILL_ALIVE $_svc"
    else
        _KILL_GONE="$_KILL_GONE $_svc"
    fi
done
echo "KILL_CENSUS: gone=[${_KILL_GONE# }] survived=[${_KILL_ALIVE# }] (empty survived list = all targets dead)"

# --- GSI WATCHDOG FEEDER (5.9.16, host namespace) --------------------------
# SAFE-BY-DESIGN: this only ADDS kicking. It never disables, closes,
# magic-closes, or stops the host watchdog or host watchdogd, and it
# never stops watchdogd. The reboots stop because kicking becomes
# reliable, not because protection is removed.
# Moved here from master_prepare.sh: the feeder now starts AFTER the
# kill spree (and after the pkill -f patterns above), so the kill
# spree is excluded as a suspect class for a dead feeder.
# Design: supervisor (restart-on-exit) + worker (open-write-close
# every 2 s, like the old feeder, so WDIOF_MAGICCLOSE keeps the timer
# running only while the loop runs). Write errors are LOGGED, never
# discarded with 2>/dev/null: the worker logs its test write, its
# first failure, every 30th failure, and a heartbeat every 30
# successful writes (~60 s), so the log proves kicking without
# flooding one line per 2 s write. A missing /dev/watchdog is logged
# the same throttled way and the worker keeps retrying.
# Liveness is REAL, not ps-grep on "/dev/watchdog": the supervisor
# PID is recorded in gsi_watchdog_feeder.pid and liveness requires
# kill -0 on that PID plus a /proc cmdline containing the exact
# supervisor script name (with a ps fallback on the exact script
# name). A legacy pre-5.9.16 feeder (cmdline containing /dev/watchdog)
# is killed before starting, because the new supervisor/worker
# cmdlines do NOT contain "/dev/watchdog" and so are not matched by
# that legacy cleanup.
gsi_feeder_alive() {
    if [ -f /data/local/tmp/gsi_watchdog_feeder.pid ]; then
        _fpid="$(cat /data/local/tmp/gsi_watchdog_feeder.pid 2>/dev/null)"
        if [ -n "$_fpid" ]; then
            if kill -0 "$_fpid" 2>/dev/null; then
                _fcl="$(tr '\0' ' ' < /proc/$_fpid/cmdline 2>/dev/null)"
                case "$_fcl" in
                    *gsi_watchdog_supervisor.sh*) return 0 ;;
                esac
            fi
        fi
    fi
    if ps -ef 2>/dev/null | grep -v grep | grep -q "gsi_watchdog_supervisor.sh"; then
        return 0
    fi
    return 1
}
if gsi_feeder_alive; then
    echo "WATCHDOG_FEEDER: supervisor already alive (pid $(cat /data/local/tmp/gsi_watchdog_feeder.pid 2>/dev/null || echo unknown)), not starting a duplicate"
else
    if [ -e /dev/watchdog ]; then
        echo "WATCHDOG_FEEDER: /dev/watchdog present, starting supervised feeder after kill spree"
    else
        echo "WATCHDOG_FEEDER: WARNING /dev/watchdog MISSING at feeder start — feeder will log this and keep retrying (host watchdog protection may be absent)"
    fi
    ls -l /dev/watchdog* 2>/dev/null || echo "WATCHDOG_FEEDER: no /dev/watchdog* nodes listed"
    pkill -f "/dev/watchdog" 2>/dev/null || true
    # 6.0 (P1): stage the native ioctl feeder binary for the
    # supervisor below. If it is missing (old extraction), the
    # supervisor falls back to the shell worker unchanged.
    if [ -f "$STAGE/watchdog_feeder" ]; then
        cp -f "$STAGE/watchdog_feeder" /data/local/tmp/watchdog_feeder 2>/dev/null || true
        chmod 755 /data/local/tmp/watchdog_feeder 2>/dev/null || true
        echo "WATCHDOG_FEEDER: native ioctl feeder staged at /data/local/tmp/watchdog_feeder"
    else
        echo "WATCHDOG_FEEDER: native feeder binary missing from $STAGE — supervisor will use the shell worker"
    fi
    cat > /data/local/tmp/gsi_watchdog_feeder.sh <<'GSIFEEDER'
#!/system/bin/sh
# GSI watchdog feeder WORKER (host namespace). Open-write-close
# /dev/watchdog every 2 s. Never magic-closes, never holds the node
# open, never touches watchdogd. Failures are logged, not discarded.
LOG=/data/local/tmp/gsi_watchdog_feeder.log
ERR=/data/local/tmp/gsi_watchdog_feeder.err
ok=0; fail=0; missing=0
echo "$(date) feeder worker started pid $$" >> "$LOG"
if [ -e /dev/watchdog ]; then
    if echo -n 1 > /dev/watchdog 2>"$ERR"; then
        echo "$(date) feeder test write OK (/dev/watchdog present)" >> "$LOG"; ok=1
    else
        echo "$(date) feeder test write FAILED: $(cat "$ERR" 2>/dev/null)" >> "$LOG"; fail=1
    fi
else
    echo "$(date) feeder test write SKIPPED: /dev/watchdog missing" >> "$LOG"; missing=1
fi
while true; do
    sleep 2
    if [ -e /dev/watchdog ]; then
        if echo -n 1 > /dev/watchdog 2>"$ERR"; then
            ok=$((ok + 1)); missing=0
            if [ $((ok % 30)) -eq 0 ]; then
                echo "$(date) feeder heartbeat: $ok writes OK, $fail failures" >> "$LOG"
            fi
        else
            fail=$((fail + 1))
            if [ "$fail" -eq 1 ] || [ $((fail % 30)) -eq 0 ]; then
                echo "$(date) feeder write FAILED (failure #$fail): $(cat "$ERR" 2>/dev/null)" >> "$LOG"
            fi
        fi
    else
        missing=$((missing + 1))
        if [ "$missing" -eq 1 ] || [ $((missing % 30)) -eq 0 ]; then
            echo "$(date) feeder: /dev/watchdog missing (missing count $missing)" >> "$LOG"
        fi
    fi
done
GSIFEEDER
    cat > /data/local/tmp/gsi_watchdog_supervisor.sh <<'GSISUPER'
#!/system/bin/sh
# GSI watchdog feeder SUPERVISOR: restart-on-exit. The worker loop
# above never exits on a single failed write, so this loop normally
# waits; if the worker process dies for any reason, it is restarted
# after 1 s and the restart is logged. Killing this supervisor alone
# does not stop protection while the worker lives, and return_to_oneui.sh
# kills both by exact script name.
LOG=/data/local/tmp/gsi_watchdog_feeder.log
while true; do
    echo "$(date) supervisor: starting feeder worker" >> "$LOG"
    # 6.0 (P1): native ioctl feeder first (held fd, WDIOC_KEEPALIVE
    # every 5 s, magic close on SIGTERM). The shell worker below is
    # the fallback if the binary is missing or not executable.
    # Supervision itself is unchanged: this supervisor, its pidfile,
    # liveness checks, the guest kicker, and the host-watchdogd
    # keepalive all stay exactly as in 5.9.16.
    if [ -x /data/local/tmp/watchdog_feeder ]; then
        /data/local/tmp/watchdog_feeder >> "$LOG" 2>&1
    else
        /system/bin/sh /data/local/tmp/gsi_watchdog_feeder.sh
    fi
    echo "$(date) supervisor: feeder worker exited, restarting in 1s" >> "$LOG"
    sleep 1
done
GSISUPER
    chmod 755 /data/local/tmp/gsi_watchdog_feeder.sh /data/local/tmp/gsi_watchdog_supervisor.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/gsi_watchdog_supervisor.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/gsi_watchdog_supervisor.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "$!" > /data/local/tmp/gsi_watchdog_feeder.pid 2>/dev/null || true
    sleep 1
    if gsi_feeder_alive; then
        echo "WATCHDOG_FEEDER_STARTED: supervisor pid $(cat /data/local/tmp/gsi_watchdog_feeder.pid 2>/dev/null || echo unknown), log /data/local/tmp/gsi_watchdog_feeder.log"
    else
        echo "WATCHDOG_FEEDER_START_FAILED: supervisor not alive after start — check /data/local/tmp/gsi_watchdog_feeder.log (guest boot continues; host watchdogd, if any, is still the kicker)"
    fi
fi

# --- PERSIST.VENDOR.SOFTDOG FALLBACK (6.2 P3, SESSION-SCOPED) -------------
# Mechanism re-implemented from OneOS (fahadalijaved): if Samsung's
# softdog cannot be fed at all (no usable node), turn it off through
# Samsung's init via persist.vendor.softdog=off — but ONLY when all
# three conditions hold: (1) a "V" write to /dev/watchdog is refused,
# (2) no active software watchdog node exists under
# /sys/class/watchdog, and (3) init.sysfw.rc contains the softdog
# trigger. The prop is session-scoped: the 6.2 persist snapshot (taken
# above) is restored by return_to_oneui.sh, which deletes this prop
# again if it was not in the snapshot. Runs AFTER the zygote stop
# above, when One UI's system_server can no longer kick the softdog.
# The timeout neutralize (moved before the kill spree in 6.2, O1) is
# the primary cover; this is the fallback when no node accepted it.
_P3_V_OK=0
_P3_V_ERR=""
if _P3_V_TMP="$(printf V 2>&1 > /dev/watchdog)"; then
    _P3_V_OK=1
else
    _P3_V_ERR="$_P3_V_TMP"
fi
_P3_SOFT_NODE=0
for _p3w in /sys/class/watchdog/watchdog*; do
    [ -d "$_p3w" ] || continue
    [ "$(cat "$_p3w/state" 2>/dev/null)" = "active" ] || continue
    case "$(cat "$_p3w/identity" 2>/dev/null)" in
        *[Ss]oft*) _P3_SOFT_NODE=1; break ;;
    esac
done
_P3_TRIGGER=0
if [ -f /system/etc/init/init.sysfw.rc ] && grep -q "softdog" /system/etc/init/init.sysfw.rc 2>/dev/null; then
    _P3_TRIGGER=1
fi
if [ "$_P3_V_OK" -eq 0 ] && [ "$_P3_SOFT_NODE" -eq 0 ] && [ "$_P3_TRIGGER" -eq 1 ]; then
    if [ -n "$RP" ] && [ -x "$RP" ]; then
        if [ -n "$_RP_SETFLAGS" ]; then
            "$RP" $_RP_SETFLAGS persist.vendor.softdog off 2>/dev/null || true
        else
            "$RP" persist.vendor.softdog off 2>/dev/null || true
        fi
        echo "PERSIST_SOFTDOG_OFF: V-write refused ($_P3_V_ERR), no active software watchdog node, init.sysfw.rc has the softdog trigger — persist.vendor.softdog=off set (now: $(getprop persist.vendor.softdog 2>/dev/null); restored on return)"
    else
        echo "PERSIST_SOFTDOG_SKIP: all three fallback conditions held but no usable resetprop — softdog cannot be turned off (timeout neutralize + feeder remain the only cover)"
    fi
else
    echo "PERSIST_SOFTDOG_SKIP: V-write ok=$_P3_V_OK, active-soft-node=$_P3_SOFT_NODE, sysfw-trigger=$_P3_TRIGGER (fallback needs 0/0/1; no change made)"
fi
unset _P3_V_OK _P3_V_ERR _P3_SOFT_NODE _P3_TRIGGER _P3_V_TMP _p3w

# --- HOST WATCHDOGD KEEPALIVE (5.9.16) ------------------------------------
# Mirrors the adbd/imsd watchdogs above, but for the HOST watchdogd:
# it only ever RESTARTS watchdogd (via init) if its init service
# exists and is not running. It never stops, kills, closes, or
# disables watchdogd, and it never writes /dev/watchdog itself — it
# is a keepalive for the host's own protection, not a replacement
# kicker. If no watchdogd service exists on this phone, it logs that
# once (state change) and the fork feeder above is the sole kicker.
gsi_keepalive_alive() {
    if [ -f /data/local/tmp/host_watchdogd_keepalive.pid ]; then
        _kpid="$(cat /data/local/tmp/host_watchdogd_keepalive.pid 2>/dev/null)"
        if [ -n "$_kpid" ]; then
            if kill -0 "$_kpid" 2>/dev/null; then
                _kcl="$(tr '\0' ' ' < /proc/$_kpid/cmdline 2>/dev/null)"
                case "$_kcl" in
                    *host_watchdogd_keepalive.sh*) return 0 ;;
                esac
            fi
        fi
    fi
    if ps -ef 2>/dev/null | grep -v grep | grep -q "host_watchdogd_keepalive.sh"; then
        return 0
    fi
    return 1
}
if gsi_keepalive_alive; then
    echo "HOST_WATCHDOGD_KEEPALIVE: already alive, not starting a duplicate"
else
    cat > /data/local/tmp/host_watchdogd_keepalive.sh <<'HOSTWD'
#!/system/bin/sh
# Host watchdogd keepalive: restart-only. Never stops watchdogd,
# never writes /dev/watchdog. Logs only on state change plus any
# restart request, so a phone with no watchdogd service logs once.
LOG=/data/local/tmp/host_watchdogd_keepalive.log
last_state=""
while true; do
    sleep 60
    _svc="$(getprop init.svc.watchdogd 2>/dev/null || echo "")"
    if pidof watchdogd >/dev/null 2>&1; then
        _state="running"
    elif [ -n "$_svc" ] && [ "$_svc" != "running" ]; then
        setprop ctl.start watchdogd 2>/dev/null
        echo "$(date) host watchdogd keepalive: watchdogd not running (init.svc.watchdogd=$_svc), requested ctl.start" >> "$LOG"
        _state="restarted:$_svc"
    else
        _state="absent"
    fi
    if [ "$_state" != "$last_state" ]; then
        echo "$(date) host watchdogd keepalive: state $last_state -> $_state" >> "$LOG"
        last_state="$_state"
    fi
done
HOSTWD
    chmod 755 /data/local/tmp/host_watchdogd_keepalive.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/host_watchdogd_keepalive.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/host_watchdogd_keepalive.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "$!" > /data/local/tmp/host_watchdogd_keepalive.pid 2>/dev/null || true
    if gsi_keepalive_alive; then
        echo "HOST_WATCHDOGD_KEEPALIVE_STARTED: pid $(cat /data/local/tmp/host_watchdogd_keepalive.pid 2>/dev/null || echo unknown), log /data/local/tmp/host_watchdogd_keepalive.log"
    else
        echo "HOST_WATCHDOGD_KEEPALIVE_START_FAILED: keepalive not alive after start (watchdogd itself is untouched)"
    fi
fi

# Suppress the host zygote only, so Samsung init does not resurrect it
nohup $BB sh -c "while true; do [ \"\$(getprop init.svc.zygote)\" = \"running\" ] && setprop ctl.stop zygote; sleep 1; done" </dev/null >/dev/null 2>&1 &

# Copy inner script and zygote_exec into container data partition
cp -f "$STAGE/master_inner.sh" "$STAGE/data/master_inner.sh"
chmod 755 "$STAGE/data/master_inner.sh"
cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
chmod 755 "$STAGE/data/zygote_exec"

# Launch takeover inside isolated mount namespace
$BB unshare -m $BB sh "$STAGE/data/master_inner.sh" "$STAGE/rootfs" </dev/null >"$STAGE/data/takeover.log" 2>&1 &
TAKEOVER_PID=$!
echo "Takeover daemon PID: $TAKEOVER_PID"
# 5.9.5-SCRIPTS-START: guest-running marker for guards.sh detection.
# return_to_oneui.sh removes this once the rootfs is unmounted.
touch "$STAGE/.guest_running" 2>/dev/null || true
# 5.9.5-SCRIPTS-END

# 5.9.16: watchdog visibility verification (host namespace). Guest
# mounts live in a separate mount namespace via unshare -m above, so
# they SHOULD NOT hide /dev/watchdog from host daemons — verify and
# log, don't assume. This check runs in the host namespace after the
# guest launch, so a FAIL here means the host's own view changed.
if [ -e /dev/watchdog ]; then
    echo "WATCHDOG_VISIBILITY_OK: host /dev/watchdog still visible after guest launch (guest mounts did not hide it from host daemons)"
    ls -l /dev/watchdog* 2>/dev/null || true
else
    echo "WATCHDOG_VISIBILITY_FAIL: host /dev/watchdog NOT visible after guest launch — host kicking may be blind this session, check mounts"
fi
if gsi_feeder_alive 2>/dev/null; then
    echo "WATCHDOG_FEEDER_ALIVE_POST_LAUNCH: supervised feeder still alive after guest launch"
else
    echo "WATCHDOG_FEEDER_DEAD_POST_LAUNCH: supervised feeder NOT alive after guest launch — check /data/local/tmp/gsi_watchdog_feeder.log"
fi

# Start UI Activator daemon
$BB sh -c "
BB=\"$BB\"
[ -n \"\$BB\" ] || BB=\$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
while true; do
    sleep 2
    PID=\$(pidof system_server | awk '{print \$1}')
    if [ -n \"\$PID\" ]; then
        if $BB nsenter -t \$PID -m /system/bin/dumpsys window 2>/dev/null | grep -q 'mStatusBar'; then
            echo '[UI Activator] WindowManager is ready! Dismissing bootanim and unlocking...'
            setprop service.bootanim.exit 1
            kill -9 \$(pidof bootanimation) 2>/dev/null
            sleep 1
            $BB nsenter -t \$PID -m /system/bin/svc power stayon true
            $BB nsenter -t \$PID -m /system/bin/settings put global stay_on_while_plugged_in 7
            $BB nsenter -t \$PID -m /system/bin/settings put system screen_off_timeout 2147483647
            $BB nsenter -t \$PID -m /system/bin/settings put system haptic_feedback_enabled 1
            $BB nsenter -t \$PID -m /system/bin/settings put system peak_refresh_rate 120.0
            $BB nsenter -t \$PID -m /system/bin/settings put system min_refresh_rate 120.0
            # Gesture navigation. The GSI boots with the three-button overlay, and
            # this line used to force it back on every takeover.
            $BB nsenter -t \$PID -m /system/bin/cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/settings put secure navigation_mode 2 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/pm disable android.ext.services/android.ext.services.notification.Assistant 2>/dev/null || true
            $BB nsenter -t \$PID -m /system/bin/input keyevent 224
            $BB nsenter -t \$PID -m /system/bin/input keyevent 82
            $BB nsenter -t \$PID -m /system/bin/am unlock-user 0
            $BB nsenter -t \$PID -m /system/bin/am start -a android.intent.action.MAIN -c android.intent.category.HOME
            echo '[UI Activator] Home activated!'
            echo '[UI Activator] Creating missing app data dirs...'
            $BB nsenter -t \$PID -m /system/bin/sh /data/local/tmp/fix_app_dirs.sh 2>/dev/null || true

            # Install microG if requested
            if [ -f \"\$STAGE/install_microg.flag\" ]; then
                echo '[UI Activator] Installing microG components...'
                for apk in \"\$STAGE/GmsCore.apk\" \"\$STAGE/FakeStore.apk\" /data/local/tmp/GmsCore.apk /data/local/tmp/FakeStore.apk; do
                    if [ -f \"\$apk\" ]; then
                        echo \"[UI Activator] Installing \$apk...\"
                        \$BB nsenter -t \$PID -m /system/bin/pm install -r -g \"\$apk\" 2>/dev/null || true
                    fi
                done
                rm -f \"\$STAGE/install_microg.flag\" 2>/dev/null || true
            fi

            # Populate network permissions for all installed packages
            for uid in \$($BB nsenter -t \$PID -m /system/bin/pm list packages -U 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | sort -u); do
                [ -n \"\$uid\" ] || continue
                b0=\$(printf \"%02x\" \$((uid & 0xff)))
                b1=\$(printf \"%02x\" \$(((uid >> 8) & 0xff)))
                b2=\$(printf \"%02x\" \$(((uid >> 16) & 0xff)))
                b3=\$(printf \"%02x\" \$(((uid >> 24) & 0xff)))
                bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_uid_permission_map key hex \$b0 \$b1 \$b2 \$b3 value hex 0c 2>/dev/null || true
            done

            # Ensure default routing
            DEF_IF=\$(ip route | grep -o 'dev [^ ]*' | head -n 1 | awk '{print \$2}')
            [ -n \"\$DEF_IF\" ] && ip route add default dev \"\$DEF_IF\" 2>/dev/null || true

            # Mount emulated primary storage
            $BB nsenter -t \$PID -m /system/bin/sm mount \"emulated;0\" 2>/dev/null || true
            break
        fi
    fi
done
" </dev/null >/data/local/tmp/ui_activator.log 2>&1 &

# 5.9.11: boot watchdog. If the guest takes over the screen but never
# reaches home, this returns the phone to One UI after 10 minutes
# instead of stranding it on the boot screen until a force-restart.
# It only runs return_to_oneui.sh (never deletes or wipes anything),
# and it exits on its own when home activates or a return runs.
# The script is synced into $STAGE by the app at boot time (see
# extractAssets); if it is somehow missing, boot proceeds without
# the watchdog rather than failing.
if [ -f "$STAGE/boot_watchdog.sh" ]; then
    chmod 755 "$STAGE/boot_watchdog.sh" 2>/dev/null || true
    nohup /system/bin/sh "$STAGE/boot_watchdog.sh" "$STAGE" </dev/null >"$STAGE/boot_watchdog.log" 2>&1 &
    echo "Boot watchdog armed (10 min): guest must reach home or the phone returns to One UI automatically"
fi

echo "=== TAKEOVER LAUNCHED SUCCESSFULLY ==="

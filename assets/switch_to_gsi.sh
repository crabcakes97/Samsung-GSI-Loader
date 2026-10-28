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
for svc in media.codec media.metrics; do
    setprop ctl.stop $svc 2>/dev/null || true
done
kill -9 $(pidof media.codec) $(pidof media.metrics) 2>/dev/null || true

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
for _svc in surfaceflinger bootanimation app_process64 zygote_exec zygote64 system_server media.codec media.metrics wificond; do
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
    /system/bin/sh /data/local/tmp/gsi_watchdog_feeder.sh
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

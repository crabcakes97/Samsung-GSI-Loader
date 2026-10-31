#!/system/bin/sh
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

echo "[Pivoted Root] Preparing pivot..."
ROOTFS_DIR="${1:-/data/local/tmp/lineage_stage/rootfs}"
cd "$ROOTFS_DIR" || { echo "[Pivoted Root] FATAL: cannot cd to $ROOTFS_DIR! Aborting."; exit 1; }
$BB mount --make-rprivate /
if ! $BB pivot_root . postinstall; then
    echo "[Pivoted Root] Fallback: bind mounting rootfs onto itself..."
    $BB mount --bind . .
    if ! $BB pivot_root . postinstall; then
        echo "[Pivoted Root] FATAL: pivot_root failed completely! Aborting."
        exit 1
    fi
fi
$BB mount -t proc proc /proc

export PATH=/system/bin:/system/xbin

echo "[Pivoted Root] Setting up /data_mirror and /data/data mounts for Zygote isolation..."
$BB mount --bind /data/user/0 /data/data 2>/dev/null || true
$BB mount -t tmpfs tmpfs /data_mirror 2>/dev/null || true
mkdir -p /data_mirror/data_de/null/0 /data_mirror/data_ce/null/0 /data_mirror/cur_profiles /data_mirror/ref_profiles
chmod -R 777 /data_mirror
$BB mount --bind /data/user_de/0 /data_mirror/data_de/null/0 2>/dev/null || true
$BB mount --bind /data/user/0 /data_mirror/data_ce/null/0 2>/dev/null || true
mkdir -p /data/misc/profiles/cur /data/misc/profiles/ref
$BB mount --bind /data/misc/profiles/cur /data_mirror/cur_profiles 2>/dev/null || true
$BB mount --bind /data/misc/profiles/ref /data_mirror/ref_profiles 2>/dev/null || true

echo "[Pivoted Root] Setting up /data/media and emulated storage..."
mkdir -p /data/media/0/Android /data/media/0/Pictures/Screenshots /data/media/0/Download /data/media/0/DCIM /data/media/0/Documents
chown -R 1023:1023 /data/media 2>/dev/null || true
chmod -R 777 /data/media 2>/dev/null || true
$BB mount -t tmpfs tmpfs /storage 2>/dev/null || true
mkdir -p /storage/emulated/0
$BB mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true
mkdir -p /mnt/user/0
$BB mount -t tmpfs tmpfs /mnt/user/0 2>/dev/null || true
mkdir -p /mnt/user/0/emulated
$BB mount --bind /data/media/0 /mnt/user/0/emulated 2>/dev/null || true

# 5.9.5-SCRIPTS-START: storage share (SHARE_FOLDER=1 only). The host
# shared dir was created by master_prepare.sh; here it is bound into
# the guest's /sdcard/GSI_Shared. A bind failure is logged and boot
# continues — the guest must still boot if the share bind fails.
if [ "$SHARE_FOLDER" = "1" ]; then
    mkdir -p /data/media/0/GSI_Shared /storage/emulated/0/GSI_Shared /sdcard/GSI_Shared 2>/dev/null || true
    if $BB mount --bind /data/media/0/GSI_Shared /sdcard/GSI_Shared 2>/dev/null; then
        echo "[Pivoted Root] SHARE_FOLDER: bound /sdcard/GSI_Shared OK"
    else
        echo "[Pivoted Root] SHARE_FOLDER: WARNING bind failed for /sdcard/GSI_Shared (continuing boot; dir exists, share may be via /storage/emulated/0/GSI_Shared)"
    fi
fi
# 5.9.5-SCRIPTS-END
# 5.9.5-SCRIPTS-START: density staging + guest-root inner ensure.
# Density cannot be applied here (wm needs system_server, not yet up):
# stage the value for fix_app_dirs post-boot if it is not already there.
if [ -n "$DENSITY_DPI" ]; then
    case "$DENSITY_DPI" in
        ''|*[!0-9]*) echo "[Pivoted Root] DENSITY: ignoring invalid DENSITY_DPI='$DENSITY_DPI'" ;;
        *) mkdir -p /data/local/tmp 2>/dev/null || true
           printf '%s\n' "$DENSITY_DPI" > /data/local/tmp/density_dpi 2>/dev/null || true
           echo "[Pivoted Root] DENSITY: staged $DENSITY_DPI dpi for post-boot wm density" ;;
    esac
fi
# GUEST_ROOT=1: ensure a host su is reachable as /system/xbin/su inside
# the guest. master_prepare.sh already bind-mounted it if the hook ran;
# this is the inner fallback (copy/bind from the host adb tree, which
# is visible inside the guest as /data/adb). Never fatal to boot.
if [ "$GUEST_ROOT" = "1" ]; then
    if [ ! -f /system/xbin/su ]; then
        for _su in /data/adb/ksu/bin/su /data/adb/ksud /data/adb/magisk/su /system/bin/su; do
            if [ -f "$_su" ]; then
                mkdir -p /system/xbin 2>/dev/null || true
                $BB mount --bind "$_su" /system/xbin/su 2>/dev/null || cp "$_su" /system/xbin/su 2>/dev/null || true
                chmod 755 /system/xbin/su 2>/dev/null || true
                break
            fi
        done
    fi
    if [ -f /system/xbin/su ]; then
        echo "[Pivoted Root] GUEST_ROOT: /system/xbin/su present (host-su bind/copy; see guest_root.sh gap note for app grants)"
    else
        echo "[Pivoted Root] GUEST_ROOT: WARNING no host su found inside guest (guest-root shell path unavailable this boot)"
    fi
fi
# 5.9.5-SCRIPTS-END
echo "[Pivoted Root] Rootfs successfully activated as /"
echo "[Pivoted Root] Testing /dev/null resolution:"
exec 8< /dev/null
echo -n "FD 8: "
$BB readlink /proc/$$/fd/8
exec 8<&-

# 6.3 (named extra): hide /proc/sysrq-trigger from the guest — a guest
# that can write SysRq can crash the host kernel. Best-effort bind of
# /dev/null over it; loud log on failure, never fatal to boot.
if [ -e /proc/sysrq-trigger ]; then
    if $BB mount --bind /dev/null /proc/sysrq-trigger 2>/dev/null; then
        echo "[Pivoted Root] SYSRQ_HIDE: /proc/sysrq-trigger hidden from guest"
    else
        echo "[Pivoted Root] SYSRQ_HIDE_WARN: could not bind /dev/null over /proc/sysrq-trigger (guest SysRq remains possible)"
    fi
fi

echo "[Pivoted Root] Testing su availability:"
su -c id || echo "su check non-fatal"

echo "[Pivoted Root] Starting guest SurfaceFlinger..."
# sf.log used to grow without bound: the guest's RenderEngine dumps LLVM IR for
# every shader it compiles ("Global Value @fullLiteral...") and got to 300+ MB in
# ~3 minutes, filling /data. SurfaceFlinger's real diagnostics go through logcat,
# so stderr can be dropped.
/system/bin/surfaceflinger > /dev/null 2>&1 &
SF_PID=$!
echo "[Pivoted Root] SurfaceFlinger PID: $SF_PID"
sleep 2

echo "[Pivoted Root] Starting guest BootAnimation..."
setprop service.bootanim.exit 0
/system/bin/bootanimation > /data/anim.log 2>&1 &
ANIM_PID=$!
echo "[Pivoted Root] BootAnimation PID: $ANIM_PID"
sleep 1

echo "[Pivoted Root] Starting guest Vold..."
/system/bin/vold --blkid_context=u:r:blkid:s0 --blkid_untrusted_context=u:r:blkid_untrusted:s0 --fsck_context=u:r:fsck:s0 --fsck_untrusted_context=u:r:fsck_untrusted:s0 > /data/vold.log 2>&1 &
VOLD_PID=$!
echo "[Pivoted Root] Vold PID: $VOLD_PID"
sleep 1

# 6.5 (diagnostic only, dive cause #5): verify guest vold actually
# registered with servicemanager, and is still alive. Never fatal,
# never restarts anything — a missing vold is evidence, not a
# boot-stopper. Same "service check" idiom as the 6.3 netd check.
_VOLD_CHECK="$(service check vold 2>/dev/null || echo "service check failed")"
if kill -0 "$VOLD_PID" 2>/dev/null; then _VOLD_ALIVE="alive (pid $VOLD_PID)"; else _VOLD_ALIVE="NOT alive (pid $VOLD_PID gone)"; fi
case "$_VOLD_CHECK" in
    *": found"*) echo "[Pivoted Root] VOLD_OK: vold owned in servicemanager ($_VOLD_CHECK); process $_VOLD_ALIVE" ;;
    *) echo "[Pivoted Root] VOLD_MISSING: vold NOT owned in servicemanager (check said: $_VOLD_CHECK); process $_VOLD_ALIVE — guest vold may have died or never registered (diagnostic only, dive cause #5)" ;;
esac

# Wifi. switch_to_gsi.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
echo "[Pivoted Root] Starting guest wificond..."
/system/bin/wificond > /data/wificond.log 2>&1 &
WIFICOND_PID=$!
echo "[Pivoted Root] wificond PID: $WIFICOND_PID"
sleep 1

# 6.3 (dive R1 — most likely stall killer): fresh host netd for the
# guest. Mechanism re-implemented from OneOS (fahadalijaved/OneOS,
# guest_start.sh "Fresh netd for the guest" — credit; no OneOS code
# copied): the DNS resolver lives in the host's netd and hands
# IDnsResolver to AID_SYSTEM only once; One UI's system_server took
# it at boot, so the guest's ConnectivityService dies on "Already
# called by AID_SYSTEM" and system_server crash-loops behind a
# looping boot animation. Restart netd and wait for dnsresolver
# re-registration BEFORE zygote launch. Never fatal: if the restart
# or wait fails, log loudly and boot anyway — a guest with broken
# connectivity is diagnosable, a refused boot is not.
echo "[Pivoted Root] 6.3 netd restart: restarting host netd for a fresh DNS resolver (dive R1)..."
_NETD_BEFORE="$(getprop init.svc.netd 2>/dev/null || echo unknown)"
setprop ctl.restart netd 2>/dev/null || echo "[Pivoted Root] NETD_RESTART_WARN: setprop ctl.restart netd failed (continuing; ConnectivityService may die on the stale resolver handoff)"
_n=0
_netd_ok=0
while [ "$_n" -lt 50 ]; do
    if [ "$(getprop init.svc.netd 2>/dev/null)" = "running" ] && service check dnsresolver 2>/dev/null | grep -q ": found"; then
        _netd_ok=1
        break
    fi
    _n=$((_n + 1))
    sleep 0.2
done
_NETD_AFTER="$(getprop init.svc.netd 2>/dev/null || echo unknown)"
_DNSR="$(service check dnsresolver 2>/dev/null | cut -d: -f2 2>/dev/null || echo unknown)"
echo "[Pivoted Root] NETD_RESTART: netd was=$_NETD_BEFORE now=$_NETD_AFTER dnsresolver:$_DNSR after $((_n / 5))s (waited ${_n} x 0.2s)"
if [ "$_netd_ok" != "1" ]; then
    echo "[Pivoted Root] NETD_RESTART_WARN: dnsresolver NOT re-registered after netd restart — guest ConnectivityService may crash-loop (dive R1 discriminator: logcat 'Already called by AID_SYSTEM')"
fi
# netd's rc may restart the host zygote when netd restarts
# ("onrestart restart zygote"); re-assert it stopped — the host-side
# suppression loop re-stops it within 1 s, but do not let a revived
# host zygote own the sockets the guest launcher is about to bind.
setprop ctl.stop zygote 2>/dev/null || true
sleep 1

# Overlay idmaps. idmap2 refuses the GSI's product overlays because framework-res
# does not declare the targeted resources as overlayable, so OMS ends up with no
# idmap at all and silently ignores every overlay: gesture navigation never
# applies (navbar stays 3-button) and the SystemUI accent overlays do nothing.
# Build the nav-bar idmap ourselves, before zygote can cache the empty overlay.
NAV_IDMAP="/data/resource-cache/system@product@overlay@NavigationBarModeGestural@NavigationBarModeGesturalOverlay.apk@idmap"
NAV_OV="/system/product/overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"
mkdir -p /data/resource-cache
if [ ! -s "$NAV_IDMAP" ] && [ -f "$NAV_OV" ]; then
    echo "[Pivoted Root] Generating gesture-nav overlay idmap..."
    /system/bin/idmap2 create --target-apk-path /system/framework/framework-res.apk \
        --overlay-apk-path "$NAV_OV" --idmap-path "$NAV_IDMAP" --ignore-overlayable \
        > /data/idmap.log 2>&1 \
        && chmod 644 "$NAV_IDMAP" && chown system:system "$NAV_IDMAP" \
        && echo "[Pivoted Root] idmap OK ($(wc -c < "$NAV_IDMAP") bytes)" \
        || echo "[Pivoted Root] idmap FAILED: $(head -n1 /data/idmap.log 2>/dev/null)"
fi

# Newly installed apps have no data directories (the guest has no installd), and
# zygote kills their first launch with "Failed to mount /data_mirror/...". This
# sweep creates them while the guest runs, so Play Store/Aurora installs become
# launchable within ~15 s.
if [ -x /system/bin/setsid ]; then
    setsid /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
else
    /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
fi
echo "[Pivoted Root] App storage sweeper started..."

echo "[Pivoted Root] Cleaning stale sockets..."
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

# 5.9.16: GUEST-SIDE watchdog kicker (defense in depth, rank 2b).
# The guest has no init and no watchdogd of its own, so previously
# kicking depended solely on host daemons surviving. /dev is
# rbind-shared into the guest (master_prepare.sh), so a guest loop
# CAN write /dev/watchdog. This starts a supervised guest kicker
# (supervisor restart-on-exit + worker open-write-close every 2 s)
# BEFORE exec'ing zygote_exec, detached via setsid so it survives
# the exec (it is reparented to host init, PID 1, like the other
# guest daemons). It does NOT replace the host feeder — both kick,
# so either side surviving keeps the 100 s timer fed.
# It never magic-closes, never holds the node open, and never stops
# watchdogd. If the host watchdogd/feeder already holds /dev/watchdog
# open, guest writes may fail EBUSY: that is LOGGED (throttled, like
# the host feeder) and is not fatal — the host kicker still protects.
# Liveness here is pidfile + /proc cmdline on the exact supervisor
# script name, not a cmdline substring on /dev/watchdog.
# On return, return_to_oneui.sh kills this kicker by its exact script
# names (and kill_guest_procs kills anything rooted under the guest
# rootfs), so it does not leak into One UI.
guest_kicker_alive() {
    if [ -f /data/guest_watchdog_kicker.pid ]; then
        _gpid="$(cat /data/guest_watchdog_kicker.pid 2>/dev/null)"
        if [ -n "$_gpid" ]; then
            if kill -0 "$_gpid" 2>/dev/null; then
                _gcl="$(tr '\0' ' ' < /proc/$_gpid/cmdline 2>/dev/null)"
                case "$_gcl" in
                    *gsi_guest_kicker_supervisor.sh*) return 0 ;;
                esac
            fi
        fi
    fi
    if ps -ef 2>/dev/null | grep -v grep | grep -q "gsi_guest_kicker_supervisor.sh"; then
        return 0
    fi
    return 1
}
if guest_kicker_alive; then
    echo "[Pivoted Root] Guest watchdog kicker already alive, not starting a duplicate"
else
    mkdir -p /data/local/tmp 2>/dev/null || true
    if [ -e /dev/watchdog ]; then
        echo "[Pivoted Root] Guest watchdog kicker: /dev/watchdog visible inside guest, starting supervised kicker"
    else
        echo "[Pivoted Root] Guest watchdog kicker: WARNING /dev/watchdog NOT visible inside guest — kicker will log this and keep retrying"
    fi
    cat > /data/local/tmp/gsi_guest_kicker.sh <<'GUESTKICKER'
#!/system/bin/sh
# Guest watchdog kicker WORKER (guest namespace, /dev rbind-shared).
# Open-write-close /dev/watchdog every 2 s. Failures logged, not discarded.
LOG=/data/guest_watchdog_kicker.log
ERR=/data/guest_watchdog_kicker.err
ok=0; fail=0; missing=0
echo "$(date) guest kicker worker started pid $$" >> "$LOG"
if [ -e /dev/watchdog ]; then
    if echo -n 1 > /dev/watchdog 2>"$ERR"; then
        echo "$(date) guest kicker test write OK" >> "$LOG"; ok=1
    else
        echo "$(date) guest kicker test write FAILED: $(cat "$ERR" 2>/dev/null)" >> "$LOG"; fail=1
    fi
else
    echo "$(date) guest kicker test write SKIPPED: /dev/watchdog missing in guest" >> "$LOG"; missing=1
fi
while true; do
    sleep 2
    if [ -e /dev/watchdog ]; then
        if echo -n 1 > /dev/watchdog 2>"$ERR"; then
            ok=$((ok + 1)); missing=0
            if [ $((ok % 30)) -eq 0 ]; then
                echo "$(date) guest kicker heartbeat: $ok writes OK, $fail failures" >> "$LOG"
            fi
        else
            fail=$((fail + 1))
            if [ "$fail" -eq 1 ] || [ $((fail % 30)) -eq 0 ]; then
                echo "$(date) guest kicker write FAILED (failure #$fail): $(cat "$ERR" 2>/dev/null)" >> "$LOG"
            fi
        fi
    else
        missing=$((missing + 1))
        if [ "$missing" -eq 1 ] || [ $((missing % 30)) -eq 0 ]; then
            echo "$(date) guest kicker: /dev/watchdog missing in guest (missing count $missing)" >> "$LOG"
        fi
    fi
done
GUESTKICKER
    cat > /data/local/tmp/gsi_guest_kicker_supervisor.sh <<'GUESTSUPER'
#!/system/bin/sh
# Guest kicker SUPERVISOR: restart-on-exit (see host supervisor note
# in switch_to_gsi.sh). The worker never exits on a single failed
# write; if it dies, it is restarted after 1 s and logged.
LOG=/data/guest_watchdog_kicker.log
while true; do
    echo "$(date) guest supervisor: starting kicker worker" >> "$LOG"
    /system/bin/sh /data/local/tmp/gsi_guest_kicker.sh
    echo "$(date) guest supervisor: kicker worker exited, restarting in 1s" >> "$LOG"
    sleep 1
done
GUESTSUPER
    chmod 755 /data/local/tmp/gsi_guest_kicker.sh /data/local/tmp/gsi_guest_kicker_supervisor.sh 2>/dev/null || true
    if [ -x /system/bin/setsid ]; then
        setsid /system/bin/sh /data/local/tmp/gsi_guest_kicker_supervisor.sh < /dev/null > /dev/null 2>&1 &
    else
        /system/bin/sh /data/local/tmp/gsi_guest_kicker_supervisor.sh < /dev/null > /dev/null 2>&1 &
    fi
    echo "$!" > /data/guest_watchdog_kicker.pid 2>/dev/null || true
    sleep 1
    if guest_kicker_alive; then
        echo "[Pivoted Root] Guest watchdog kicker STARTED (supervisor pid $(cat /data/guest_watchdog_kicker.pid 2>/dev/null || echo unknown), log /data/guest_watchdog_kicker.log)"
    else
        echo "[Pivoted Root] Guest watchdog kicker START_FAILED (host feeder is still the kicker; check /data/guest_watchdog_kicker.log)"
    fi
fi

# 6.0 (P4): aconfig pre-population. Android 17 guests expect
# aconfig packages (including android.xr) in /metadata/aconfig;
# without them aconfigd-system aborts and system_server/AppOps fail.
# Populate maps + boot values from the guest's own partitions and
# every mounted APEX, stage the synthetic android.xr package data
# (from /data/xr.* staged by master_prepare.sh), then run the
# aconfigd-system init steps. All best-effort: a guest without
# aconfigd must still boot, and a missing /metadata bind only logs.
echo "[Pivoted Root] 6.0 aconfig pre-population..."
mkdir -p /metadata/aconfig/maps /metadata/aconfig/boot 2>/dev/null || true
if [ -d /metadata/aconfig/maps ] && [ -d /metadata/aconfig/boot ]; then
    chmod 775 /metadata/aconfig 2>/dev/null || true
    chown root:system /metadata/aconfig 2>/dev/null || true
    for _part in system system_ext product vendor odm; do
        _src=""
        for _cand in "/$_part/etc/aconfig" "/system/$_part/etc/aconfig" "/system/product/etc/aconfig"; do
            if [ -d "$_cand" ]; then _src="$_cand"; break; fi
        done
        if [ -n "$_src" ]; then
            cp -f "$_src/package.map" "/metadata/aconfig/maps/${_part}.package.map" 2>/dev/null || true
            cp -f "$_src/flag.map" "/metadata/aconfig/maps/${_part}.flag.map" 2>/dev/null || true
            cp -f "$_src/flag.val" "/metadata/aconfig/boot/${_part}.val" 2>/dev/null || true
            cp -f "$_src/flag.info" "/metadata/aconfig/boot/${_part}.info" 2>/dev/null || true
        fi
    done
    for _amap in /apex/*/etc/aconfig/package.map; do
        [ -f "$_amap" ] || continue
        _adir="$(dirname "$(dirname "$_amap")")"
        _mname="$(basename "$_adir")"
        cp -f "$_adir/etc/aconfig/package.map" "/metadata/aconfig/maps/${_mname}.package.map" 2>/dev/null || true
        cp -f "$_adir/etc/aconfig/flag.map" "/metadata/aconfig/maps/${_mname}.flag.map" 2>/dev/null || true
        cp -f "$_adir/etc/aconfig/flag.val" "/metadata/aconfig/boot/${_mname}.val" 2>/dev/null || true
        cp -f "$_adir/etc/aconfig/flag.info" "/metadata/aconfig/boot/${_mname}.info" 2>/dev/null || true
    done
    for _ext in flag.map info package.map val; do
        if [ -f "/data/xr.$_ext" ]; then
            case "$_ext" in
                flag.map|package.map) cp -f "/data/xr.$_ext" "/metadata/aconfig/maps/xr.$_ext" 2>/dev/null || true ;;
                *) cp -f "/data/xr.$_ext" "/metadata/aconfig/boot/xr.$_ext" 2>/dev/null || true ;;
            esac
        fi
    done
    if [ -x /system/bin/aconfigd-system ]; then
        /system/bin/aconfigd-system early-platform-init 2>/dev/null || true
        /system/bin/aconfigd-system platform-init 2>/dev/null || true
        echo "[Pivoted Root] aconfigd-system init steps run"
    else
        echo "[Pivoted Root] aconfig: no /system/bin/aconfigd-system in guest (pre-population only)"
    fi
    chmod -R 755 /metadata/aconfig 2>/dev/null || true
    chmod 644 /metadata/aconfig/maps/* /metadata/aconfig/boot/* 2>/dev/null || true
    chown -R root:system /metadata/aconfig 2>/dev/null || true
    echo "[Pivoted Root] aconfig pre-population done"
else
    echo "[Pivoted Root] ACONFIG_WARN: /metadata/aconfig not writable (host /metadata bind missing?) — skipping pre-population (guest boots without it)"
fi
# 6.4 (research R1 / dive cause #4): guest-derived classpaths.
# Mechanism re-implemented from OneOS (fahadalijaved/OneOS,
# guest_start.sh derive_classpath invocation — credit; no OneOS
# code copied): on a normal boot init runs the guest's own
# /apex/com.android.sdkext/bin/derive_classpath and consumes its
# export lines; nothing does that in the container, so the guest
# zygote would otherwise inherit zygote_exec's baked 23.2-era
# lists (or the host's). Run the guest's tool here — APEX mounts
# are done (prepare ran pre-pivot) and zygote has not launched —
# export what it emits, and leave a genv wrapper so host-side
# commands entered via nsenter get the same exports. ANY failure
# (missing binary, non-zero exit, empty output, zero exports)
# falls back to the baked lists LOUDLY and never fails the boot.
echo "[Pivoted Root] 6.4 deriving guest classpaths (research R1)..."
_DERIVE=/apex/com.android.sdkext/bin/derive_classpath
_CLASSPATH_FILE=/data/system/environ/classpath
_DERIVE_OK=0
mkdir -p /data/system/environ 2>/dev/null || true
if [ -x "$_DERIVE" ]; then
    if "$_DERIVE" "$_CLASSPATH_FILE" > /data/derive_classpath.log 2>&1; then
        if [ -s "$_CLASSPATH_FILE" ]; then
            _n=0
            while IFS= read -r _line || [ -n "$_line" ]; do
                case "$_line" in
                    export\ *)
                        _rest="${_line#export }"
                        case "$_rest" in
                            *=*) _k="${_rest%%=*}"; _v="${_rest#*=}" ;;
                            *\ *) _k="${_rest%% *}"; _v="${_rest#* }" ;;
                            *) _k=""; _v="" ;;
                        esac
                        if [ -n "$_k" ] && [ -n "$_v" ]; then
                            export "$_k=$_v"
                            _n=$((_n + 1))
                        fi
                        ;;
                esac
            done < "$_CLASSPATH_FILE"
            if [ "$_n" -gt 0 ]; then
                _DERIVE_OK=1
                echo "[Pivoted Root] CLASSPATH_DERIVED: $_n classpath exports from $_CLASSPATH_FILE (guest derive_classpath OK)"
                sed 's/^/[Pivoted Root]   /' "$_CLASSPATH_FILE" 2>/dev/null | cut -c1-300
            fi
        fi
    fi
fi
if [ "$_DERIVE_OK" != "1" ]; then
    echo "[Pivoted Root] CLASSPATH_FALLBACK: WARNING derive_classpath unavailable/failed/empty — zygote keeps baked 23.2-era lists (check /data/derive_classpath.log)"
    sed 's/^/[Pivoted Root]   /' /data/derive_classpath.log 2>/dev/null | head -5
fi
# genv wrapper for host-side commands entered via nsenter: same
# exports as the zygote environment, sourced from the classpath
# file when present; execs the given command with them applied.
cat > /data/gsi_genv.sh <<'GSIGENV'
#!/system/bin/sh
[ -f /data/system/environ/classpath ] && while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
        export\ *)
            _rest="${_line#export }"
            case "$_rest" in
                *=*) _k="${_rest%%=*}"; _v="${_rest#*=}" ;;
                *\ *) _k="${_rest%% *}"; _v="${_rest#* }" ;;
                *) _k=""; _v="" ;;
            esac
            [ -n "$_k" ] && [ -n "$_v" ] && export "$_k=$_v"
            ;;
    esac
done < /data/system/environ/classpath
exec "$@"
GSIGENV
chmod 755 /data/gsi_genv.sh 2>/dev/null || true
echo "[Pivoted Root] genv wrapper written: /data/gsi_genv.sh"
# 6.0 (P3): supervised zygote restart loop WITH backoff + cap. The
# old single exec ended the session outright on any zygote death. A
# zygote that crashes instantly must not spin forever: after 5
# consecutive quick failures (run under 120 s) the loop gives up
# loudly and the inner script exits so the session ends
# diagnosably instead of spinning. A run that lasted 120 s or more
# resets the failure count (a late crash is a runtime failure, not
# a boot loop).
echo "[Pivoted Root] Launching guest Zygote & SystemServer via zygote_exec (supervised, 6.0 P3)..."
# 6.8: stdio capture mode switch (decisive experiment for the FD 68
# FIFO abort). 6.9: default = file (stdio straight onto the log as
# a regular file, no pipe/writer, no shell step needed). Pipe mode
# (the 6.5 design) is the opt-in A/B alternative, selected WITHOUT
# a rebuild: set GSI_ZYGOTE_STDIO_MODE=pipe in the environment, or
# create the marker file /data/gsi_stdio_pipe_mode (guest /data =
# staged slot data dir; host-side:
# /data/local/tmp/lineage_stage/data/gsi_stdio_pipe_mode — create
# it from a root shell before tapping Boot, remove it to return to
# file mode). The legacy 6.8 /data/gsi_stdio_file_mode marker is
# harmless if present (file is the default anyway) and is no
# longer consulted. The launcher logs the active mode
# (ZYGOTE_STDIO_MODE) in zygote_exec.log. Anything else = file.
if [ "$GSI_ZYGOTE_STDIO_MODE" = "pipe" ] || [ -e /data/gsi_stdio_pipe_mode ]; then
    export GSI_ZYGOTE_STDIO_MODE=pipe
    echo "[Pivoted Root] ZYGOTE_STDIO_MODE: pipe (6.5 design; env/marker selected)"
else
    export GSI_ZYGOTE_STDIO_MODE=file
    echo "[Pivoted Root] ZYGOTE_STDIO_MODE: file (default)"
fi
# 6.5: zygote stdio capture. zygote_exec captures zygote's stdout +
# stderr into /data/zygote_stdio.log (append; pipe+writer or
# regular file per the mode switch above); the supervisor adds
# a session header once and an attempt separator before each
# launch so attempts stay separable in one file. The file lives
# in guest /data (the staged slot data dir) and survives the
# session ending, so the bundle / Previous Logs can read it.
# Appending here is best-effort: if /data is unwritable the
# writer child reports it loudly in zygote_exec.log instead.
{ echo "===== GSI Loader 6.5 zygote stdio capture — session started $(date) ====="; } >> /data/zygote_stdio.log 2>/dev/null || echo "[Pivoted Root] ZYGOTE_STDIO_CAPTURE_WARN: cannot append to /data/zygote_stdio.log (check ZYGOTE_STDIO_CAPTURE_* lines in zygote_exec.log)"
echo "[Pivoted Root] ZYGOTE_STDIO_CAPTURE: zygote stdout/stderr captured to /data/zygote_stdio.log (append, per attempt)"
_ZYGOTE_FAILS=0
_ZYGOTE_DELAY=2
while true; do
    _ZYGOTE_START="$(date +%s 2>/dev/null || echo 0)"
    echo "===== zygote attempt $((_ZYGOTE_FAILS + 1)) at $(date) =====" >> /data/zygote_stdio.log 2>/dev/null || true
    /data/zygote_exec
    _ZYGOTE_RET=$?
    _ZYGOTE_END="$(date +%s 2>/dev/null || echo 0)"
    _ZYGOTE_RUN=$((_ZYGOTE_END - _ZYGOTE_START))
    # Exit-vs-signal distinction (6.5): the loop runs zygote_exec
    # in the foreground and captures $? directly — no pipeline,
    # no time wrapper — so a plain code IS the genuine exit
    # status. A signal death arrives as 128+signo; report it as
    # a kill, not a code, so "code 0" is never misread.
    if [ "$_ZYGOTE_RET" -gt 128 ]; then
        echo "[Pivoted Root] zygote_exec KILLED by signal $((_ZYGOTE_RET - 128)) after ${_ZYGOTE_RUN}s at $(date) (shell status $_ZYGOTE_RET)"
    else
        echo "[Pivoted Root] zygote_exec exited with code $_ZYGOTE_RET after ${_ZYGOTE_RUN}s at $(date)"
    fi
    if [ "$_ZYGOTE_RUN" -ge 120 ]; then
        _ZYGOTE_FAILS=0
        _ZYGOTE_DELAY=2
        echo "[Pivoted Root] zygote ran >= 120s before exiting: failure count reset (runtime crash, not a boot loop)"
    else
        _ZYGOTE_FAILS=$((_ZYGOTE_FAILS + 1))
        if [ "$_ZYGOTE_FAILS" -gt 5 ]; then
            echo "[Pivoted Root] ZYGOTE_RESTART_CAP_REACHED: 5 consecutive quick zygote failures — giving up (check /data/zygote_stdio.log, /data/zygote_exec.log and /data/logcat_cap.txt; session ends)"
            # 6.5: cap-time host logcat snapshot BEFORE the inner
            # script exits. The session ends ~1 min in, long
            # before the 600 s boot watchdog, so the watchdog's
            # boot diagnostics never run; this snapshot is the
            # Java/ART death message. Guest logd output reaches
            # the host logd via the bound /dev. Filtered tags
            # first; an empty/failed filtered snapshot falls
            # back to the unfiltered tail — the snapshot is
            # never dropped entirely. Never fatal, never blocks
            # return.
            _LOGCAT_BIN="$(command -v logcat 2>/dev/null || echo /system/bin/logcat)"
            echo "[Pivoted Root] ZYGOTE_CAP_LOGCAT: snapshotting host logcat to /data/logcat_cap.txt (filtered tags first, unfiltered fallback)..."
            if "$_LOGCAT_BIN" -d -t 1000 '*:F' zygote:V system_server:V art:V AndroidRuntime:V > /data/logcat_cap.txt 2>/dev/null && [ -s /data/logcat_cap.txt ]; then
                echo "[Pivoted Root] ZYGOTE_CAP_LOGCAT_OK: filtered snapshot saved ($(wc -l < /data/logcat_cap.txt 2>/dev/null || echo ?) lines)"
            elif "$_LOGCAT_BIN" -d -t 1000 > /data/logcat_cap.txt 2>/dev/null && [ -s /data/logcat_cap.txt ]; then
                echo "[Pivoted Root] ZYGOTE_CAP_LOGCAT_FALLBACK: filtered snapshot empty/failed — unfiltered tail saved ($(wc -l < /data/logcat_cap.txt 2>/dev/null || echo ?) lines)"
            else
                echo "ZYGOTE_CAP_LOGCAT: logcat snapshot FAILED (no logcat output captured)" > /data/logcat_cap.txt 2>/dev/null || true
                echo "[Pivoted Root] ZYGOTE_CAP_LOGCAT_FAILED: no logcat output captured (see /data/logcat_cap.txt marker)"
            fi
            break
        fi
    fi
    echo "[Pivoted Root] restarting zygote_exec in ${_ZYGOTE_DELAY}s (quick failure $_ZYGOTE_FAILS/5)"
    sleep "$_ZYGOTE_DELAY"
    _ZYGOTE_DELAY=$((_ZYGOTE_DELAY * 2))
    if [ "$_ZYGOTE_DELAY" -gt 30 ]; then
        _ZYGOTE_DELAY=30
    fi
done
echo "[Pivoted Root] zygote supervisor loop ended — inner script exiting"

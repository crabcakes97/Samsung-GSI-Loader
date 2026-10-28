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

# Wifi. switch_to_gsi.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
echo "[Pivoted Root] Starting guest wificond..."
/system/bin/wificond > /data/wificond.log 2>&1 &
WIFICOND_PID=$!
echo "[Pivoted Root] wificond PID: $WIFICOND_PID"
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

echo "[Pivoted Root] Launching guest Zygote & SystemServer via zygote_exec..."
exec /data/zygote_exec

#!/system/bin/sh
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
# 5.9.5-SCRIPTS-START: stage containment (guards.sh). If guards.sh has
# not been extracted yet, continue with the legacy validation above
# rather than breaking boot on an old install.
if [ -f "$STAGE/guards.sh" ]; then
    . "$STAGE/guards.sh"
    gsi_validate_stage "$STAGE" || { echo "!!! INVALID STAGE (guards): $STAGE"; exit 1; }
fi
# 5.9.5-SCRIPTS-END
ROOTFS="$STAGE/rootfs"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

# 6.2 (P10): resolve system_ext / product inside the guest rootfs.
# In a GSI, /system_ext is often an ABSOLUTE symlink (/system/system_ext)
# and /system/product an absolute symlink (/product); in this (host)
# namespace those resolve to HOST paths, so a bind or copy using the
# unresolved path lands on the host tree while the guest keeps its own
# (OneOS's finding: PMS then aborts parsing apex paths host apexd
# reports but the guest tree lacks). Mechanism re-implemented from
# OneOS (fahadalijaved): pick the candidate that is a real directory.
# gsi_resolve_rootfs_dir echoes the real in-rootfs dir for a logical
# name; if neither candidate is a real dir it echoes the legacy path
# (current behavior, logged loudly by the caller) rather than failing
# the boot on an odd image.
gsi_resolve_rootfs_dir() {
    case "$1" in
        system_ext)
            if [ -d "$ROOTFS/system_ext" ] && [ ! -L "$ROOTFS/system_ext" ]; then
                echo "$ROOTFS/system_ext"
            elif [ -d "$ROOTFS/system/system_ext" ] && [ ! -L "$ROOTFS/system/system_ext" ]; then
                echo "$ROOTFS/system/system_ext"
            else
                echo "$ROOTFS/system_ext"
            fi
            ;;
        product)
            if [ -d "$ROOTFS/system/product" ] && [ ! -L "$ROOTFS/system/product" ]; then
                echo "$ROOTFS/system/product"
            elif [ -d "$ROOTFS/product" ] && [ ! -L "$ROOTFS/product" ]; then
                echo "$ROOTFS/product"
            else
                echo "$ROOTFS/system/product"
            fi
            ;;
        *) echo "$ROOTFS/$1" ;;
    esac
}

# Generic-GSI patch flags, written by the app as $STAGE/gsi_flags.conf.
# DEFAULT IS ALL OFF: the patched files below were built against LineageOS
# 23.2's framework and are version-coupled. Binding them over an arbitrary
# GSI can break boot, so they are only applied when the user explicitly
# enabled them (Lineage presets enable them by default in the app UI).
# A missing flags file means "no patches" — never silently patch.
PATCH_FRAMEWORK=0
PATCH_PERMISSION_CONTROLLER=0
USE_LINEAGE_APEX_LIST=0
if [ -f "$STAGE/gsi_flags.conf" ]; then
    . "$STAGE/gsi_flags.conf"
fi
echo "Patch flags: PATCH_FRAMEWORK=$PATCH_FRAMEWORK PATCH_PERMISSION_CONTROLLER=$PATCH_PERMISSION_CONTROLLER USE_LINEAGE_APEX_LIST=$USE_LINEAGE_APEX_LIST"

echo "=== 1. Watchdog feeder (deferred — NOT started here) ==="
# 5.9.16: the host watchdog feeder is NO LONGER started here. Starting it
# in master_prepare meant it ran BEFORE the kill spree in
# switch_to_gsi.sh, so the kill spree could never be excluded as a
# suspect class for a dead feeder. switch_to_gsi.sh now starts the
# supervised feeder AFTER the kill spree (see that script's
# "GSI WATCHDOG FEEDER" section), and return_to_oneui.sh kills it on
# return. This step only records the pre-takeover watchdog-node state
# for the log; it writes nothing to /dev/watchdog and starts nothing.
# Host protection is NOT weakened by this deferral: the feeder starts
# later in the same takeover, before the guest is launched, and the
# host watchdogd (if any) is untouched throughout.
if [ -e /dev/watchdog ]; then
    echo "WATCHDOG_FEEDER_DEFERRED: /dev/watchdog present; feeder will start in switch_to_gsi.sh after the kill spree"
else
    echo "WATCHDOG_FEEDER_DEFERRED: WARNING /dev/watchdog MISSING at prepare time — feeder start in switch_to_gsi.sh will log this and keep retrying"
fi
ls -l /dev/watchdog* 2>/dev/null || echo "WATCHDOG_FEEDER_DEFERRED: no /dev/watchdog* nodes listed"

echo "=== 2. Creating Loop Device Nodes ==="
for i in $(seq 50 150); do
    minor=$((i * 8))
    rm -f /dev/block/loop$i /dev/loop$i 2>/dev/null || true
    mknod /dev/block/loop$i b 7 $minor
    mknod /dev/loop$i b 7 $minor
done

echo "=== 3. Mounting system.raw if needed ==="
if mount | grep -q "$ROOTFS "; then
    if [ ! -f "$ROOTFS/system/bin/sh" ] || [ ! -f "$ROOTFS/init.environ.rc" ]; then
        echo "Rootfs mount is invalid or stale. Unmounting..."
        while mount | grep -q "$ROOTFS"; do
            $BB umount -l "$ROOTFS" 2>/dev/null || true
            sleep 0.1
        done
    else
        echo "Rootfs already mounted and healthy."
    fi
fi

mkdir -p "$ROOTFS"
if ! mount | grep -q "$ROOTFS "; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$STAGE/system.raw"
    echo "Using LOOP: $LOOP"
    # 5.9.13: name the filesystem being mounted, and warn early if
    # the host kernel shows no EROFS support. The warning is NOT
    # fatal: the mount below still decides, and module autoload may
    # provide EROFS even when /proc/filesystems does not list it yet.
    # A fatal refusal here would false-positive on exactly the phones
    # that would have worked. If the mount then fails, the MOUNT
    # FAILED error below (plus this warning) names the cause.
    if type gsi_fs_type >/dev/null 2>&1; then
        _fstype="$(gsi_fs_type "$STAGE/system.raw")"
        echo "system.raw filesystem: $_fstype"
        if [ "$_fstype" = "erofs" ] && ! grep -q "erofs" /proc/filesystems 2>/dev/null; then
            echo "WARNING: system.raw is EROFS but 'erofs' is not listed in /proc/filesystems — if the mount below fails, the host kernel likely lacks EROFS support (not a corrupt image)"
        fi
    fi
    # Any GSI: try ext4 first, fall back to EROFS (many current GSIs ship EROFS).
    $BB mount -t ext4 -o ro "$LOOP" "$ROOTFS" 2>/dev/null || $BB mount -t erofs -o ro "$LOOP" "$ROOTFS"
    # Mount failure must be fatal and loud: without this check the script
    # prints its success banner over a non-rootfs and boot fails cryptically.
    if [ ! -f "$ROOTFS/system/bin/sh" ] || [ ! -f "$ROOTFS/init.environ.rc" ]; then
        echo "!!! MOUNT FAILED: system.raw did not mount as a valid rootfs (tried ext4, then erofs). Aborting before any binds."
        exit 1
    fi
fi

mkdir -p "$ROOTFS/postinstall" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" \
    "$ROOTFS/linkerconfig" "$ROOTFS/vendor" "$ROOTFS/odm" "$ROOTFS/vendor_dlkm" \
    "$ROOTFS/mnt" "$ROOTFS/storage" "$ROOTFS/apex" "$ROOTFS/data"
# 5.9.13: name any expected rootfs dir the image lacks. On a read-only
# rootfs mkdir cannot create them, so a missing dir makes its bind fail
# silently downstream — log it loudly now so a failed boot is
# diagnosable. Warning only: the guest may still boot without some.
for _d in postinstall dev proc sys linkerconfig vendor odm vendor_dlkm mnt storage apex data system/framework system/apex system/xbin; do
    [ -e "$ROOTFS/$_d" ] || echo "WARNING: guest rootfs lacks /$_d (binds targeting it will fail)"
done

echo "=== 4. Setting up Core System Bind Mounts ==="
mount | grep -q "$ROOTFS/proc " || $BB mount -t proc proc "$ROOTFS/proc"
# 6.2 (P2): bind the HOST /sys (rbind + rslave) instead of a fresh
# sysfs mount, so the guest sees the host cgroup2 hierarchy at
# /sys/fs/cgroup. Mechanism re-implemented from OneOS (fahadalijaved):
# without the host cgroup2 hierarchy the guest zygote cannot put
# system_server in a process group (createProcessGroup fails) and it
# dies on fork — animation runs, logo stalls, ~100 s later the unfed
# softdog panics. That is the prime suspect for the logo-stage panic.
# rslave keeps guest-side mount changes from propagating back to the
# host. Fallback: fresh sysfs if the rbind fails (logged loudly; the
# guest then has NO host cgroup2, as in 6.1 and earlier). Tradeoff,
# stated plainly: the guest (root, setenforce 0) can write host sysfs
# nodes, the same exposure OneOS accepts with this mechanism.
if mount | grep -q "$ROOTFS/sys "; then
    echo "SYS_MOUNT_EXISTING: $ROOTFS/sys already mounted: $(mount 2>/dev/null | grep "$ROOTFS/sys " | head -n 1)"
elif $BB mount --rbind /sys "$ROOTFS/sys" 2>/dev/null; then
    if $BB mount --make-rslave "$ROOTFS/sys" 2>/dev/null; then
        echo "SYS_RBIND_OK: host /sys rbound into guest (rslave); guest sees host cgroup2 hierarchy at /sys/fs/cgroup (6.2 P2)"
    else
        echo "SYS_RBIND_WARN: host /sys rbound but --make-rslave failed (guest mount changes may propagate to host; cgroup2 still visible)"
    fi
    if [ -d "$ROOTFS/sys/fs/cgroup" ]; then
        echo "SYS_CGROUP_OK: guest /sys/fs/cgroup is present (host cgroup2 hierarchy visible)"
    else
        echo "SYS_CGROUP_WARN: guest /sys/fs/cgroup NOT present after rbind (system_server may die on fork; see SYS_RBIND lines)"
    fi
else
    echo "SYS_RBIND_FAIL: host /sys rbind failed — falling back to fresh sysfs (guest will NOT see host cgroup2; system_server may die on fork, as in 6.1)"
    $BB mount -t sysfs sysfs "$ROOTFS/sys" 2>/dev/null || echo "SYS_MOUNT_FAIL: fresh sysfs mount also failed"
fi

if [ ! -e /dev/binderfs/binder ]; then
    mount -t binder binder /dev/binderfs 2>/dev/null || true
    chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null || true
fi

$BB mount --make-rprivate "$ROOTFS" 2>/dev/null || true

if ! mount | grep -q "$ROOTFS/dev "; then
    $BB mount --rbind /dev "$ROOTFS/dev"
    $BB mount --make-rprivate "$ROOTFS/dev"
fi

mount | grep -q "$ROOTFS/linkerconfig " || $BB mount --rbind /linkerconfig "$ROOTFS/linkerconfig"
mount | grep -q "$ROOTFS/vendor " || $BB mount --bind /vendor "$ROOTFS/vendor"
mount | grep -q "$ROOTFS/odm " || $BB mount --bind /odm "$ROOTFS/odm"
mount | grep -q "$ROOTFS/vendor_dlkm " || $BB mount --bind /vendor_dlkm "$ROOTFS/vendor_dlkm"
# 6.0 (P9): bind the remaining vendor-module partitions newer guests
# expect — odm_dlkm, system_dlkm, config — each only if present on
# the host. A missing host dir means no bind (logged by absence, not
# failure): the guest simply does not see that partition.
if [ -d /odm_dlkm ]; then
    mkdir -p "$ROOTFS/odm_dlkm" 2>/dev/null || true
    if mount | grep -q "$ROOTFS/odm_dlkm " || $BB mount --bind /odm_dlkm "$ROOTFS/odm_dlkm" 2>/dev/null; then
        echo "Bound /odm_dlkm -> $ROOTFS/odm_dlkm (6.0 P9)"
    fi
fi
if [ -d /system_dlkm ]; then
    mkdir -p "$ROOTFS/system_dlkm" 2>/dev/null || true
    if mount | grep -q "$ROOTFS/system_dlkm " || $BB mount --bind /system_dlkm "$ROOTFS/system_dlkm" 2>/dev/null; then
        echo "Bound /system_dlkm -> $ROOTFS/system_dlkm (6.0 P9)"
    fi
fi
if [ -d /config ]; then
    mkdir -p "$ROOTFS/config" 2>/dev/null || true
    if mount | grep -q "$ROOTFS/config " || $BB mount --rbind /config "$ROOTFS/config" 2>/dev/null; then
        echo "Bound /config -> $ROOTFS/config (6.0 P9)"
    fi
fi
# 6.0 (P5): cleared preloaded-classes. A foreign guest's preload list
# can reference classes its own framework lacks, crashing zygote at
# preload; bind an empty list over it. The target file exists in the
# read-only rootfs, so the bind itself always works when the file is
# present; a failure is logged, never fatal to prepare.
if [ -f "$ROOTFS/system/etc/preloaded-classes" ]; then
    mkdir -p "$STAGE/etc" 2>/dev/null || true
    echo "# Cleared preloaded-classes for guest GSI (6.0 P5)" > "$STAGE/etc/preloaded-classes" 2>/dev/null || true
    if $BB mount --bind "$STAGE/etc/preloaded-classes" "$ROOTFS/system/etc/preloaded-classes" 2>/dev/null; then
        echo "PRELOADED_CLASSES_CLEARED: guest preload list replaced with empty list (6.0 P5)"
    else
        echo "PRELOADED_CLASSES_WARN: bind failed (guest preload list left as-is)"
    fi
fi
# 6.0 (P4): /vendor/etc/aconfig overlay. Samsung's vendor lacks
# etc/aconfig, which makes the guest's aconfigd-system abort. Overlay
# host /vendor/etc with a writable upper layer in $STAGE so the
# aconfig dir can be created without touching the host vendor, then
# stage the guest's product aconfig files into it. Fallback (no
# overlayfs): tmpfs + rebind each entry. Best-effort: if both fail,
# the inner-script pre-population still runs and the failure is
# logged loudly below.
if [ ! -d "$ROOTFS/vendor/etc/aconfig" ]; then
    mkdir -p "$STAGE/vendor_etc_upper" "$STAGE/vendor_etc_work" 2>/dev/null || true
    if ! $BB mount -t overlay overlay -o lowerdir=/vendor/etc,upperdir="$STAGE/vendor_etc_upper",workdir="$STAGE/vendor_etc_work" "$ROOTFS/vendor/etc" 2>/dev/null; then
        echo "ACONFIG_OVERLAY_FALLBACK: overlayfs failed on vendor/etc, using tmpfs + rebind"
        $BB mount -t tmpfs tmpfs "$ROOTFS/vendor/etc" 2>/dev/null || true
        for _item in /vendor/etc/*; do
            [ -e "$_item" ] || continue
            _base="$(basename "$_item")"
            if [ -d "$_item" ]; then
                mkdir -p "$ROOTFS/vendor/etc/$_base" 2>/dev/null || true
                $BB mount --bind "$_item" "$ROOTFS/vendor/etc/$_base" 2>/dev/null || true
            else
                touch "$ROOTFS/vendor/etc/$_base" 2>/dev/null || true
                $BB mount --bind "$_item" "$ROOTFS/vendor/etc/$_base" 2>/dev/null || true
            fi
        done
    fi
    mkdir -p "$ROOTFS/vendor/etc/aconfig" 2>/dev/null || true
    # 6.2 (P10): read the guest's product aconfig through the resolved
    # product dir — $ROOTFS/system/product is an absolute symlink
    # (/product) in many GSIs, which would read the HOST's product
    # aconfig instead of the guest's.
    _GUEST_PRODUCT="$(gsi_resolve_rootfs_dir product)"
    if [ -L "$ROOTFS/system/product" ]; then
        echo "PRODUCT_RESOLVED: guest /system/product is a symlink; reading aconfig from $_GUEST_PRODUCT (6.2 P10)"
    fi
    cp -a "$_GUEST_PRODUCT/etc/aconfig/"* "$ROOTFS/vendor/etc/aconfig/" 2>/dev/null || true
    if [ -d "$ROOTFS/vendor/etc/aconfig" ]; then
        echo "ACONFIG_OVERLAY_OK: vendor/etc/aconfig staged (6.0 P4)"
    else
        echo "ACONFIG_OVERLAY_FAIL: could not create vendor/etc/aconfig (aconfigd-system may abort; inner pre-population still runs)"
    fi
fi
# 6.0 (P4): bind host /metadata so the inner script's
# /metadata/aconfig pre-population lands on a writable partition.
if [ -d /metadata ]; then
    mkdir -p "$ROOTFS/metadata" 2>/dev/null || true
    if mount | grep -q "$ROOTFS/metadata " || $BB mount --rbind /metadata "$ROOTFS/metadata" 2>/dev/null; then
        echo "ACONFIG_METADATA_BIND: host /metadata bound into guest (6.0 P4)"
    fi
fi
# 6.0 (P4): stage the synthetic android.xr aconfig data into guest
# /data (the inner script copies it into /metadata/aconfig).
mkdir -p "$STAGE/data" 2>/dev/null || true
for _x in xr.flag.map xr.info xr.package.map xr.val; do
    if [ -f "$STAGE/$_x" ]; then
        cp -f "$STAGE/$_x" "$STAGE/data/$_x" 2>/dev/null || true
    fi
done
# apexd is a HOST daemon: it reports the Samsung apex set (/system/apex,
# /system_ext/apex, /vendor/apex) to the container system_server, which then
# tries to parse those exact paths inside this namespace. Keep the apex
# directories identical to what host apexd sees (an empty tmpfs or the GSI's
# own .capex layout makes PMS abort with "Unable to parse" at boot).
# 6.2 (P10): resolve system_ext before binding (see resolver above).
_GUEST_SYSTEM_EXT="$(gsi_resolve_rootfs_dir system_ext)"
if [ -L "$ROOTFS/system_ext" ]; then
    echo "SYS_EXT_RESOLVED: guest /system_ext is a symlink; using $_GUEST_SYSTEM_EXT for the apex bind (6.2 P10)"
fi
if [ -d /system_ext/apex ]; then
    mkdir -p "$_GUEST_SYSTEM_EXT/apex"
    mount | grep -q "$_GUEST_SYSTEM_EXT/apex " || $BB mount --bind /system_ext/apex "$_GUEST_SYSTEM_EXT/apex"
fi
mount | grep -q "$ROOTFS/mnt " || $BB mount --rbind /mnt "$ROOTFS/mnt"
# 5.9.5-SCRIPTS-START: framework patch gating. The patched jars/apk
# in $STAGE were built against LineageOS 23.2's framework and are
# version-coupled. FRAMEWORK_VERSION comes from Java's build.prop
# detection (env var, or $STAGE/framework_version as a fallback file).
# Patched set is currently 23.2 ONLY. Any other version SKIPS all patch
# bind-mounts (framework + PermissionController) — 23.2 jars are never
# applied to a non-23.2 guest silently. If FRAMEWORK_VERSION is not
# provided at all, legacy flag behaviour is kept (with a warning),
# because the 5.9.4 Lineage presets enable patches without passing a
# version; Java should always pass FRAMEWORK_VERSION going forward.
if [ -z "$FRAMEWORK_VERSION" ] && [ -f "$STAGE/framework_version" ]; then
    FRAMEWORK_VERSION="$(head -n 1 "$STAGE/framework_version" 2>/dev/null | tr -d ' \r\n')"
fi
if [ -n "$FRAMEWORK_VERSION" ]; then
    case "$FRAMEWORK_VERSION" in
        *23.2*)
            echo "Framework patch gating: version $FRAMEWORK_VERSION is in the patched set (23.2)"
            ;;
        *)
            echo "patches unavailable for framework $FRAMEWORK_VERSION — guest boots unpatched"
            PATCH_FRAMEWORK=0
            PATCH_PERMISSION_CONTROLLER=0
            ;;
    esac
else
    echo "WARNING: FRAMEWORK_VERSION not provided — patch gating skipped, flags control patches"
fi
# 6.0 (P6): guest SDK detection from the guest's own build.prop
# (alongside Java's FRAMEWORK_VERSION gating above). Used only by
# the Android 17 services-patch branch below.
GUEST_SDK=""
for _bp in "$ROOTFS/system/build.prop" "$ROOTFS/system/etc/build.prop" "$ROOTFS/build.prop" "$ROOTFS/etc/build.prop"; do
    if [ -f "$_bp" ]; then
        GUEST_SDK="$(grep -m1 '^ro.build.version.sdk=' "$_bp" 2>/dev/null | cut -d= -f2 | tr -d '\r')"
        [ -n "$GUEST_SDK" ] && break
    fi
done
if [ -n "$GUEST_SDK" ]; then
    echo "GUEST_SDK_DETECTED: sdk=$GUEST_SDK (framework_version=${FRAMEWORK_VERSION:-unset})"
else
    echo "GUEST_SDK_DETECTED: sdk=unknown (no build.prop sdk found)"
fi
# 5.9.5-SCRIPTS-END
# 5.9.16: dead-flag cleanup. The old block only echoed three fix
# flags and explicitly ignored the dev-options one ("no workaround
# available in this build"). The echoes and the ignored-flag branch
# are removed so no log or UI can imply a dev-options / IMS / codec
# fix exists. Scripts tolerate the env vars being absent: nothing
# else in this file reads them (verified by grep), and unset vars
# simply expand empty under POSIX sh here.
# (No replacement fix is claimed: there is still no dev-options
# workaround in this build.)
# Framework patches: gated on PATCH_FRAMEWORK. Presence of the files in
# $STAGE alone must NOT trigger a bind (the app always extracts them).
# 5.9.13: a failed framework bind is FATAL (named error + abort), not
# silent. These binds were previously unchecked: if one failed (e.g.
# the target file is missing from this image's layout — a real risk
# on a differently-built EROFS image), the guest booted with a MIX of
# patched and unpatched framework files, which crashes system_server
# minutes into startup in a way no log explains. Failing fast here
# turns that mysterious boot crash into a named prepare error. (The
# PermissionController bind below stays warning-only: it is a second
# pass whose absence degrades permission dialogs, not boot itself.)
if [ "$PATCH_FRAMEWORK" = "1" ]; then
    if [ -f "$STAGE/services_patched.jar" ]; then
        $BB umount -l "$ROOTFS/system/framework/services.jar" 2>/dev/null || true
        $BB mount --bind "$STAGE/services_patched.jar" "$ROOTFS/system/framework/services.jar" || { echo "!!! PATCH_BIND_FAILED: services_patched.jar -> $ROOTFS/system/framework/services.jar (aborting — a half-patched framework crashes the guest)"; exit 1; }
        echo "Bound services_patched.jar -> $ROOTFS/system/framework/services.jar"
    fi
    if [ -f "$STAGE/framework_patched.jar" ]; then
        $BB umount -l "$ROOTFS/system/framework/framework.jar" 2>/dev/null || true
        $BB mount --bind "$STAGE/framework_patched.jar" "$ROOTFS/system/framework/framework.jar" || { echo "!!! PATCH_BIND_FAILED: framework_patched.jar -> $ROOTFS/system/framework/framework.jar (aborting — a half-patched framework crashes the guest)"; exit 1; }
        echo "Bound framework_patched.jar -> $ROOTFS/system/framework/framework.jar"
    fi
    if [ -f "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" ]; then
        $BB umount -l "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so" 2>/dev/null || true
        $BB mount --bind "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so" || { echo "!!! PATCH_BIND_FAILED: libaudio_aidl_conversion_common_cpp_patched.so (aborting — a half-patched framework crashes the guest)"; exit 1; }
        echo "Bound libaudio_aidl_conversion_common_cpp_patched.so"
    fi
    if [ -f "$STAGE/libaudioclient_aidl_conversion_patched.so" ]; then
        $BB umount -l "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so" 2>/dev/null || true
        $BB mount --bind "$STAGE/libaudioclient_aidl_conversion_patched.so" "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so" || { echo "!!! PATCH_BIND_FAILED: libaudioclient_aidl_conversion_patched.so (aborting — a half-patched framework crashes the guest)"; exit 1; }
        echo "Bound libaudioclient_aidl_conversion_patched.so"
    fi
    if [ -f "$STAGE/framework-res_patched.apk" ]; then
        $BB umount -l "$ROOTFS/system/framework/framework-res.apk" 2>/dev/null || true
        $BB mount --bind "$STAGE/framework-res_patched.apk" "$ROOTFS/system/framework/framework-res.apk" || { echo "!!! PATCH_BIND_FAILED: framework-res_patched.apk -> $ROOTFS/system/framework/framework-res.apk (aborting — a half-patched framework crashes the guest)"; exit 1; }
        echo "Bound framework-res_patched.apk -> $ROOTFS/system/framework/framework-res.apk"
    fi
else
    echo "Framework patches DISABLED by gsi_flags.conf (generic GSI mode): using the GSI's own framework untouched"
fi
# 6.0 (P6): Android 17 services-patch branch — SHIPPED DISABLED.
# The candidate jar (services_android17_patched.jar) is binary-only
# with unverified provenance, and no stock A17 services jar exists
# on the build VM to DEX-diff it against, so the verification gate
# cannot pass. Until a DEX-level comparison against stock A17
# services is done, A17 guests boot UNPATCHED (same as 5.9.x) and
# this branch only logs. To enable after verification: ship the
# verified jar as $STAGE/services_android17_patched.jar and set
# PATCH_A17_SERVICES=1 in gsi_flags.conf.
PATCH_A17_SERVICES="${PATCH_A17_SERVICES:-0}"
if [ "$GUEST_SDK" = "37" ]; then
    if [ "$PATCH_A17_SERVICES" = "1" ] && [ -f "$STAGE/services_android17_patched.jar" ]; then
        $BB umount -l "$ROOTFS/system/framework/services.jar" 2>/dev/null || true
        $BB mount --bind "$STAGE/services_android17_patched.jar" "$ROOTFS/system/framework/services.jar" || { echo "!!! PATCH_BIND_FAILED: services_android17_patched.jar (aborting — a half-patched framework crashes the guest)"; exit 1; }
        echo "Bound services_android17_patched.jar -> $ROOTFS/system/framework/services.jar (A17 branch, verified jar)"
    else
        echo "A17_SERVICES_PATCH_DISABLED: guest SDK 37 detected but the A17 services patch is DISABLED (binary-only jar, unverified provenance, no DEX-vs-stock check possible) — guest boots with its own unpatched services.jar"
    fi
fi

if [ "$PATCH_PERMISSION_CONTROLLER" = "1" ] && [ -f "$STAGE/PermissionController_patched.apk" ]; then
    chmod 644 "$STAGE/PermissionController_patched.apk"
    PERM_APK=$(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null | head -n 1)
    if [ -n "$PERM_APK" ]; then
        $BB umount -l "$PERM_APK" 2>/dev/null || true
        $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK"
        echo "Bound PermissionController_patched.apk -> $PERM_APK"
    fi
elif [ "$PATCH_PERMISSION_CONTROLLER" != "1" ]; then
    echo "PermissionController patch DISABLED by gsi_flags.conf (generic GSI mode)"
fi



echo "=== 5. Setting up Isolated Data & Bridges ==="
mkdir -p "$STAGE/data/adb" "$STAGE/data/apex" "$STAGE/data/dalvik-cache/arm64"

# Give the guest the host's authorised ADB keys. The container has no
# AdbDebuggingManager (the guest system_server registers no "adb" service), so a
# guest adbd or wireless-debugging session cannot answer an authorisation prompt;
# pre-seeding the keys is the only way it can accept this machine silently.
# Pre-seed adb_enabled=1 into the guest's settings before its system_server runs.
# The in-boot fix (in fix_app_dirs.sh) only lands once the framework is up, but
# UsbDeviceManager drops the adb USB function within seconds of system_server
# starting -- which is why adb dies right after the guest boots and macOS stops
# seeing the phone entirely. Writing the XML now keeps the gadget stable through
# the whole boot.
GSET="$STAGE/data/system/users/0/settings_global.xml"
# 6.3 (dive R2): numeric-id settings seeding + repair of poisoned
# staged files. Mechanism re-implemented from OneOS
# (fahadalijaved/OneOS, seed_settings — credit; no OneOS code
# copied): inserting <setting id="adb_enabled" .../> gave the entry a
# NON-numeric id, which makes SettingsProvider fail to parse the
# file and abort system_server. Only ever (a) change the value of an
# existing name="adb_enabled" entry, or (b) insert with the next free
# NUMERIC id. Any line a previous run inserted with the bad
# non-numeric id is deleted first (repair — never the whole file),
# and each edit is verified: a failed edit restores the backup
# instead of leaving a half-written file. Never fatal: if the file
# is absent or not a text XML file, the guest creates it and the UI
# activator sets adb_enabled once the guest is up.
if [ -f "$GSET" ] && [ "$(head -c 5 "$GSET" 2>/dev/null)" = "<?xml" ]; then
    _gset_bak="$GSET.gsi-prev"
    cp -f "$GSET" "$_gset_bak" 2>/dev/null || true
    if grep -q 'id="adb_enabled"' "$GSET" 2>/dev/null; then
        _repaired=$(grep -c 'id="adb_enabled"' "$GSET" 2>/dev/null || true)
        sed -i '/id="adb_enabled"/d' "$GSET" 2>/dev/null || true
        echo "SETTINGS_REPAIR: removed ${_repaired:-0} poisoned non-numeric-id adb_enabled line(s) from staged settings_global.xml (dive R2)"
    fi
    if grep -q 'name="adb_enabled"' "$GSET" 2>/dev/null; then
        sed -i '/name="adb_enabled"/s/ value="[^"]*"/ value="1"/' "$GSET" 2>/dev/null || true
        if ! grep -q 'name="adb_enabled" value="1"' "$GSET" 2>/dev/null; then
            sed -i 's/ name="adb_enabled"/ name="adb_enabled" value="1"/' "$GSET" 2>/dev/null || true
        fi
    else
        _maxid=$(awk -F'id="' '{for(i=2;i<=NF;i++){split($i,a,"\""); if(a[1] ~ /^[0-9]+$/) print a[1]}}' "$GSET" 2>/dev/null | sort -n | tail -1)
        _nextid=$(( ${_maxid:-0} + 1 ))
        sed -i "s#</settings>#    <setting id=\"$_nextid\" name=\"adb_enabled\" value=\"1\" package=\"android\" />\n</settings>#" "$GSET" 2>/dev/null || true
        echo "SETTINGS_SEED: inserted adb_enabled=1 with numeric id=$_nextid"
    fi
    _got=$(grep -c 'name="adb_enabled" value="1"' "$GSET" 2>/dev/null || true)
    if [ "${_got:-0}" != "1" ] || ! tail -c 32 "$GSET" 2>/dev/null | grep -q '</settings>'; then
        cp -f "$_gset_bak" "$GSET" 2>/dev/null || true
        echo "SETTINGS_SEED_WARN: edit did not verify (restored staged settings_global.xml unchanged; adb_enabled will be set by the UI activator once the guest is up)"
    else
        echo "Pre-seeded adb_enabled=1 in guest settings_global.xml (numeric id, verified)"
    fi
    rm -f "$_gset_bak" 2>/dev/null || true
else
    echo "SETTINGS_SEED: no text settings_global.xml staged yet (guest creates it; UI activator sets adb_enabled once up)"
fi

if [ -f /data/misc/adb/adb_keys ]; then
    mkdir -p "$STAGE/data/misc/adb"
    cp -f /data/misc/adb/adb_keys "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        chmod 640 "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        echo "Copied host adb_keys into the guest /data"
fi
if [ -f "$STAGE/zygote_exec" ]; then
    cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
    chmod 755 "$STAGE/data/zygote_exec"
fi
mkdir -p "$STAGE/data/user/0" "$STAGE/data/user_de/0"
mkdir -p "$STAGE/data/system/users/0" "$STAGE/data/system_de/0/spblob" "$STAGE/data/system_ce/0"
mkdir -p "$STAGE/data/misc/user/0" "$STAGE/data/misc_de/0" "$STAGE/data/misc_ce/0"
mkdir -p "$STAGE/data/anr" "$STAGE/data/app" "$STAGE/data/rollback" "$STAGE/data/incremental"

for pkg in com.android.providers.settings \
           com.android.providers.telephony \
           com.android.phone \
           com.android.systemui \
           com.android.settings \
           com.android.launcher3 \
           com.android.inputmethod.latin \
           com.android.providers.media \
           com.android.providers.downloads \
           com.android.providers.contacts \
           com.android.providers.calendar \
           com.cronch.gsiloader; do
    mkdir -p "$STAGE/data/user_de/0/$pkg/databases" \
             "$STAGE/data/user_de/0/$pkg/shared_prefs" \
             "$STAGE/data/user_de/0/$pkg/files/datastore/education" \
             "$STAGE/data/user/0/$pkg/databases" \
             "$STAGE/data/user/0/$pkg/shared_prefs" \
             "$STAGE/data/user/0/$pkg/files"
done

mkdir -p "$STAGE/data/resource-cache"
chmod 771 "$STAGE/data/resource-cache"
chown 1000:1000 "$STAGE/data/resource-cache"

rm -rf "$STAGE/data/data" 2>/dev/null || true
mkdir -p "$STAGE/data/data"

chmod -R 777 "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/anr" "$STAGE/data/data" 2>/dev/null || true
chown -R 1000:1000 "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" 2>/dev/null || true
chown -R 10109:10109 "$STAGE/data/user_de/0/com.android.inputmethod.latin" "$STAGE/data/user/0/com.android.inputmethod.latin" 2>/dev/null || true

# Create the bluetooth stack's storage before the guest ever starts. The GSI's
# GD stack asserts out of storage_module.cc if it cannot persist bt_config.conf,
# and the staged tree never had this directory, so com.android.bluetooth
# crash-looped every 4 s from early boot. uid 1002 = bluetooth.
mkdir -p "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null
chown 1002:1002 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true
chmod 0770 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true

# SELinux labels matter just as much as modes here. Every directory below lives
# under /data/local/tmp, so it is created as u:object_r:shell_data_file:s0. The
# guest's system_server runs in u:r:system_server:s0 (Samsung policy) and is
# denied both read and write on shell_data_file: chmod 777 does not help, because
# the denial is MAC, not DAC. That broke UserManagerService (users/0.xml EACCES),
# EntropyMixer/BatteryStats/PackageWatchdog ("Failed to create directory for
# *.new") and finally the settings provider:
#   SQLiteCantOpenDatabaseException: /data/user_de/0/com.android.providers.settings/databases/settings.db
# Relabel the staged tree the way a real /data is labeled. The host bind mounts
# that live inside this tree (/data/apex, /data/adb, /data/media) are deliberately
# excluded so host data never gets relabeled.
echo "=== 5b. Relabeling staged /data for guest SELinux ==="
$BB chcon u:object_r:system_data_file:s0 "$STAGE/data" 2>/dev/null || true
for d in data/system data/system_de data/system_ce data/user data/user_de \
         data/misc data/misc_de data/misc_ce data/anr data/dalvik-cache \
         data/local data/resource-cache data/app data/rollback data/incremental; do
    [ -e "$STAGE/$d" ] && $BB chcon -R u:object_r:system_data_file:s0 "$STAGE/$d" 2>/dev/null || true
done
for d in "$STAGE/data/user/0" "$STAGE/data/user_de/0"; do
    if [ -d "$d" ]; then
        $BB chcon u:object_r:system_data_file:s0 "$d" 2>/dev/null || true
        $BB chcon -R u:object_r:app_data_file:s0 "$d"/* 2>/dev/null || true
    fi
done
# data/apex (host /data/apex) and data/adb (host /data/adb) are left alone: they
# are the host's own directories bind-mounted in, already labeled correctly, and
# chcon-ing a bind mount would relabel the host's copy.

echo "=== 5c. Fixing staged /data ownership and modes ==="
# The stage tree is created by root under /data/local/tmp, so its top-level
# directories come out root:root 0755. A real /data is system:system 0771, and
# system_server (uid 1000) has to be able to create /data/app/vmdl*.tmp:
#   Failed to prepare session dir: /data/app/vmdl10992519.tmp
# With 0755 root:root that mkdir gets EACCES and *every* install fails, which is
# what "non-system apps / downloads crash" looked like from the outside.
$BB chown system:system "$STAGE/data" 2>/dev/null || true
$BB chmod 0771 "$STAGE/data" 2>/dev/null || true
for d in app app-staging anr dalvik-cache incremental property resource-cache rollback ss system; do
    [ -e "$STAGE/data/$d" ] || mkdir -p "$STAGE/data/$d" 2>/dev/null || continue
    $BB chown system:system "$STAGE/data/$d" 2>/dev/null || true
    $BB chmod 0771 "$STAGE/data/$d" 2>/dev/null || true
done
mkdir -p "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0" 2>/dev/null || true
$BB chown system:system "$STAGE/data/misc" "$STAGE/data/misc/profiles" 2>/dev/null || true
for d in "$STAGE/data/misc/profiles/cur" "$STAGE/data/misc/profiles/ref" \
         "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0"; do
    [ -d "$d" ] && $BB chown system:system "$d" 2>/dev/null || true
done

echo "=== 5d. Bridging host /data app trees into the staged /data ==="
# installd and artd are HOST daemons (started by Samsung init, they cannot be
# moved into the container namespace). Left alone they create every app data
# dir, dalvik-cache entry and dexopt profile in the real /data, which the guest
# can never see - so every app process the guest zygote forks dies with:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>:
#   No such file or directory
# ("Failed to attach" / "start timeout" in ActivityManager.) Bind the staged
# equivalents over those host paths for the duration of the session, so those
# daemons write into the guest's data. One UI is not running meanwhile and
# return_to_oneui.sh removes the binds again.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    mkdir -p "$STAGE/data/$d" 2>/dev/null || true
    if [ -d "/data/$d" ] && ! mount | grep -q " /data/$d "; then
        $BB mount --bind "$STAGE/data/$d" "/data/$d" 2>/dev/null && echo "Bridged /data/$d -> $STAGE/data/$d"
    fi
done

mount | grep -q "$ROOTFS/data " || $BB mount --bind "$STAGE/data" "$ROOTFS/data"
mount | grep -q "$ROOTFS/data/adb " || $BB mount --bind /data/adb "$ROOTFS/data/adb"
mount | grep -q "$ROOTFS/data/apex " || $BB mount --bind /data/apex "$ROOTFS/data/apex"
mkdir -p "$ROOTFS/data/media"
mount | grep -q "$ROOTFS/data/media " || $BB mount --bind /data/media "$ROOTFS/data/media" 2>/dev/null || true

echo "=== 5e. Writing per-package data-dir helper ==="
# Apps installed before the /data bridge existed have no CE/DE data dirs in the
# guest tree, and the guest zygote refuses to fork them:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>
# This helper recreates the dirs for every package the guest knows about, with
# the uid PMS reports. switch_to_gsi.sh runs it once the container is up.
mkdir -p "$STAGE/data/local/tmp" 2>/dev/null || true
cat > "$STAGE/data/local/tmp/fix_app_dirs.sh" <<'FIXAPPDIRS'
#!/system/bin/sh
# Create missing CE/DE data dirs (and dexopt profile dirs) for every installed
# package, using the uid PMS reports. Idempotent.
created=0
profile_dirs=0
pkg=""
for tok in $(pm list packages -U 2>/dev/null); do
    case "$tok" in
        package:*) pkg="${tok#package:}"; uid="" ;;
        uid:*)     uid="${tok#uid:}" ;;
        *)         continue ;;
    esac
    [ -n "$pkg" ] && [ -n "$uid" ] || continue
    for d in "/data/user/0/$pkg" "/data/user_de/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0700 "$d" 2>/dev/null
            created=$((created + 1))
        fi
    done
    for d in "/data/misc/profiles/cur/0/$pkg" "/data/misc/profiles/ref/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0771 "$d" 2>/dev/null
            profile_dirs=$((profile_dirs + 1))
        fi
    done
    pkg=""; uid=""
done
echo "[fix_app_dirs] created $created data dirs, $profile_dirs profile dirs"

# Realign ownership of pre-existing data dirs with the uid PMS assigned.
# The staged /data tree was restored from a backup, so some app dirs are still
# owned by system:system with 0777 perms. ART then refuses to load any dex from
# them ("Writable dex file ... is not allowed"), and GMS/SQLite cannot chmod its
# own files ("FileUtils.setPermissions" warnings) and the app dies. Only dirs
# whose top-level owner is wrong are touched, so later boots stay cheap.
realigned=0
if [ -f /data/system/packages.list ]; then
    while read -r pkg auid rest; do
        case "$auid" in ''|*[!0-9]*) continue ;; esac
        for base in /data/user/0 /data/user_de/0; do
            d="$base/$pkg"
            [ -d "$d" ] || continue
            cur=$(stat -c %u "$d" 2>/dev/null)
            [ "$cur" = "$auid" ] && continue
            chown -R "$auid:$auid" "$d" 2>/dev/null
            chmod -R go-w "$d" 2>/dev/null
            realigned=$((realigned + 1))
        done
    done < /data/system/packages.list
fi
echo "[fix_app_dirs] realigned $realigned data dirs to their app uid"

# Gesture navigation. The UI activator writes navigation_mode too, but it can
# run before the settings provider is ready, which leaves the value at 0 and
# the navbar back to 3-button. Do it again here, after boot completed.
cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null
settings put secure navigation_mode 2 2>/dev/null

# Keep Messaging as the default SMS app. Without a holder of
# android.app.role.SMS the framework's InboundSmsHandler drops every incoming
# text before it reaches the provider, so a delivered code would vanish.
if [ "$(settings get secure sms_default_application)" != "com.android.messaging" ]; then
    cmd role add-role-holder --user 0 android.app.role.SMS com.android.messaging 2>/dev/null
    settings put secure sms_default_application com.android.messaging 2>/dev/null
    echo "[fix_app_dirs] restored default SMS app"
fi

# Bluetooth's GD stack asserts out of `storage_module.cc SaveImmediately` when
# it cannot persist its own config, and com.android.bluetooth then restarts
# every ~4 seconds for the rest of the session (1880 tombstones in one boot).
# The staged tree had no /data/misc/bluedroid at all; create it with the
# bluetooth uid (1002) so the stack can save bt_config.conf.
if [ ! -d /data/misc/bluedroid ]; then
    mkdir -p /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chown 1002:1002 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chmod 0770 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    echo "[fix_app_dirs] created /data/misc/bluedroid for the bluetooth stack"
fi

# Code files must not be writable by the app that loads them. ART rejects any
# dex/apk/jar the calling uid could modify ("Writable dex file ... is not
# allowed"), which crash-looped GMS: its Dynamite modules in
# /data/user_de/0/.../app_chimera were installed 0755. The ownership pass above
# only touches dirs whose *top-level* owner is wrong, so GMS was skipped even
# though its files were wrong. Do this on both storages, cheaply.
code_files=0
for root in /data/user/0 /data/user_de/0; do
    [ -d "$root" ] || continue
    for f in $(find "$root" -type f \( -name '*.apk' -o -name '*.jar' -o -name '*.dex' \) -perm -0200 2>/dev/null); do
        chmod a-w "$f" 2>/dev/null && code_files=$((code_files + 1))
    done
done
echo "[fix_app_dirs] made $code_files code files read-only"

# The guest's Settings.Global.ADB_ENABLED defaults to null (treated as 0), and
# the guest's UsbDeviceManager drops the adb function from the USB gadget as
# soon as it starts. That is what kills the host adbd we rely on: adb dies
# seconds after the guest boots and macOS stops seeing the phone at all. Turn it
# on so the gadget keeps adb, and read back what actually happened.
adb_before=$(getprop sys.usb.state)
settings put global adb_enabled 1 2>/dev/null
# 5.9.11: readiness check: proceed once usb.state changes (max 2s,
# was a fixed 2s sleep). The echo below reads back the new state.
_i=0; while [ $_i -lt 20 ]; do [ "$(getprop sys.usb.state)" != "$adb_before" ] && break; _i=$((_i + 1)); sleep 0.1; done
echo "[fix_app_dirs] adb_enabled=1 (usb.state was '$adb_before', now '$(getprop sys.usb.state)')"

# 5.9.5-SCRIPTS: density (DENSITY_DPI, staged by master_prepare.sh into
# /data/local/tmp/density_dpi before boot). Applied here, after boot,
# via wm density — the guest system_server must be up for wm to work,
# so density cannot be applied at pivot time. Limits: this does not
# patch build.prop (the image is mounted read-only, and EROFS is
# read-only by design), so anything reading ro.sf.lcd_density directly
# still sees the original value; the boot animation runs at the
# original density and only the post-boot UI uses the new one. The
# value is re-applied on every boot because fix_app_dirs runs on
# every boot via the UI activator.
if [ -f /data/local/tmp/density_dpi ]; then
    _dpi=$(tr -d ' \r\n' < /data/local/tmp/density_dpi 2>/dev/null)
    case "$_dpi" in
        ''|*[!0-9]*) echo "[fix_app_dirs] ignoring invalid density_dpi: $_dpi" ;;
        *) wm density "$_dpi" 2>/dev/null && echo "[fix_app_dirs] density set to $_dpi" || echo "[fix_app_dirs] wm density $_dpi failed" ;;
    esac
fi

# Record system services that failed to start (e.g. AdbService: "Failure
# starting ..."), so a problem behind a later crash can be traced without
# guessing from a fresh boot.
# SystemServer reports a service that threw during startup as
# "BOOT FAILURE starting X" (reportWtf) or "Failure starting X": catch both,
# plus anything mentioning AdbService, since that is the one we care about.
{
    logcat -d -b system 2>/dev/null | grep -a -E "BOOT FAILURE|Failure starting" | head -40
    echo "--- AdbService mentions ---"
    logcat -d -b system 2>/dev/null | grep -a -i "AdbService" | tail -10
} > /data/boot_failures.log 2>/dev/null || true
FIXAPPDIRS
chmod 755 "$STAGE/data/local/tmp/fix_app_dirs.sh" 2>/dev/null || true

# The guest has no installd, so nothing creates an app's data directories when
# it is installed. PMS records the package, then zygote aborts the first launch
# with "Failed to mount /data_mirror/data_de/null/0/<pkg> to
# /data/user_de/0/<pkg>: No such file or directory". Every app installed from
# inside the guest -- Play Store, Aurora, adb -- used to crash on launch this way.
# Create the scaffolding installd would; /data_mirror is a bind of these trees.
cat > "$STAGE/data/local/tmp/ensure_app_storage.sh" <<'ENSUREAPP'
#!/system/bin/sh
created=0
[ -f /data/system/packages.list ] || exit 0
realigned=0
while read -r pkg auid rest; do
    case "$auid" in ''|*[!0-9]*) continue ;; esac
    for d in "/data/user/0/$pkg:0771" "/data/user_de/0/$pkg:0700"; do
        p=${d%:*}; mode=${d##*:}
        if [ -d "$p" ]; then
            # Reinstalling a package can assign a NEW uid while the old data
            # dirs survive (uninstall has no installd to delete them), and the
            # app then fails with "SQLiteCantOpenDatabaseException: unable to
            # open database file" because it cannot write its own directory.
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:$auid" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:$auid" "$p" 2>/dev/null
        chmod "$mode" "$p" 2>/dev/null
        created=$((created + 1))
    done
    # External storage: owner is the app, group is ext_data_rw (1078).
    for kind in data media obb; do
        p="/data/media/0/Android/$kind/$pkg"
        if [ -d "$p" ]; then
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:1078" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:1078" "$p" 2>/dev/null
        chmod 0770 "$p" 2>/dev/null
        created=$((created + 1))
    done
done < /data/system/packages.list

# Shared storage skeleton. Without it MediaProvider cannot create
# /storage/emulated/0/Pictures/Screenshots and taking a screenshot crashes
# SystemUI ("Failed to create directory: .../.pending-NNN"), and every save
# dialog has nowhere to put its file.
for d in Pictures Pictures/Screenshots DCIM DCIM/Camera Movies Music Documents \
         Alarms Notifications Podcasts Ringtones Download; do
    p="/data/media/0/$d"
    [ -d "$p" ] && continue
    mkdir -p "$p" 2>/dev/null || continue
    chown 1023:1023 "$p" 2>/dev/null
    chmod 0775 "$p" 2>/dev/null
    created=$((created + 1))
done

if [ "$created" -gt 0 ] || [ "$realigned" -gt 0 ]; then
    echo "[ensure_app_storage] created $created dirs, realigned $realigned to new uids"
fi
exit 0
ENSUREAPP
chmod 755 "$STAGE/data/local/tmp/ensure_app_storage.sh" 2>/dev/null || true

# A new install only becomes launchable once the dirs above exist, so sweep
# while the guest is running instead of at boot only. Started by master_inner.
cat > "$STAGE/data/local/tmp/net_fix.sh" <<'NETFIX'
#!/system/bin/sh
# The guest's ConnectivityService cannot install its routes into the host's
# netd: every addRoute fails with "No such file or directory", so the final
# catch-all ip rule keeps pointing at a table from a previous network and all
# traffic ends in the "unreachable" rule. Symptom: the modem reports
# MOBILE[LTE] CONNECTED / VALIDATED, yet every app (Aurora, Play Store) says
# "check your internet connection" and even ping to the gateway fails.
# Keep a private table (4242) in sync with the live interface - wifi first,
# else mobile/CLAT - and point a catch-all rule at it. Idempotent.
have_v4() { ip -4 addr show "$1" 2>/dev/null | grep -q "inet "; }
iface=""
if have_v4 wlan0; then
    iface=wlan0
else
    for d in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^rmnet_data'); do
        if have_v4 "$d"; then iface=$d; break; fi
    done
fi
[ -z "$iface" ] && exit 0
subnet=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$2=="dev" && $3==d && $0 ~ /scope link/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {print $1; exit}')
[ -z "$subnet" ] && exit 0
gw=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$1=="default" && $2=="via" && $4=="dev" && $5==d && $3 ~ /^[0-9]+\./ {print $3; exit}')
# no IPv4 default anywhere (netd never installed one): assume the first host
[ -z "$gw" ] && gw="${subnet%.*}.1"
ip route replace "$subnet" dev "$iface" table 4242 2>/dev/null
ip route replace default via "$gw" dev "$iface" table 4242 2>/dev/null
# Priority must beat the per-uid rules netd already installed for previous
# networks (15040/29040/29998): app sockets carry an fwmark, so a catch-all
# placed after those still sends them into a dead table even though root's
# unmarked pings work.
cur=$(ip rule show 2>/dev/null | awk '/^14999:/{print $NF; exit}')
if [ "$cur" != "4242" ]; then
    ip rule del priority 14999 2>/dev/null
    ip rule add from all lookup 4242 priority 14999 2>/dev/null
    ip rule del priority 31999 2>/dev/null
    echo "net route repaired: $iface $subnet gw $gw"
fi
exit 0
NETFIX
chmod 755 "$STAGE/data/local/tmp/net_fix.sh" 2>/dev/null || true

cat > "$STAGE/data/local/tmp/app_storage_loop.sh" <<'APPLOOP'
#!/system/bin/sh
# Watches for installs/removals, gives the new package its data dirs, and makes
# the launcher re-query so the app actually shows up.
last=""
while true; do
    sleep 10
    case "$(getprop sys.boot_completed)" in 1) ;; *) continue ;; esac
    netout=$(/system/bin/sh /data/local/tmp/net_fix.sh 2>/dev/null)
    [ -n "$netout" ] && echo "$(date) $netout" >> /data/app_storage.log
    cur=$(md5sum /data/system/packages.list 2>/dev/null | cut -d' ' -f1)
    out=$(/system/bin/sh /data/local/tmp/ensure_app_storage.sh 2>/dev/null)
    if [ -n "$last" ] && { [ "$cur" != "$last" ] || [ -n "$out" ]; }; then
        # A package appeared or went away. LauncherApps caches the app list, so
        # something installed from Aurora or Play Store is missing from both the
        # drawer and app search until the launcher re-queries. Restarting the
        # launcher forces that and does not touch whatever app is in front.
        am force-stop com.android.launcher3 2>/dev/null
        echo "$(date) package list changed -> launcher refreshed ${out:+($out)}" >> /data/app_storage.log
    elif [ -n "$out" ]; then
        echo "$(date) $out" >> /data/app_storage.log
    fi
    last=$cur
done
APPLOOP
chmod 755 "$STAGE/data/local/tmp/app_storage_loop.sh" 2>/dev/null || true

echo "=== 6. Setting up /system/xbin/su (KernelSU Bridge) ==="
if ! mount | grep -q "$ROOTFS/system/xbin "; then
    $BB mount -t tmpfs tmpfs "$ROOTFS/system/xbin"
    SU_SRC="/data/adb/ksud"
    [ -f "$SU_SRC" ] || SU_SRC=$(which su 2>/dev/null)
    [ -f "$SU_SRC" ] || SU_SRC=$(find /data/adb /system/bin -name su 2>/dev/null | head -n 1)
    [ -f "$SU_SRC" ] && cp "$SU_SRC" "$ROOTFS/system/xbin/su" && chmod 755 "$ROOTFS/system/xbin/su"
fi

echo "=== 7. Setting up Fresh APEX tmpfs ==="
# Clean any stale submounts and ensure a clean, writable tmpfs
for m in $(cat /proc/mounts 2>/dev/null | grep "$ROOTFS/apex" | awk '{print $2}' | sort -r); do
    $BB umount -l "$m" 2>/dev/null || true
done
$BB umount -l "$ROOTFS/apex" 2>/dev/null || true
$BB mount -t tmpfs tmpfs "$ROOTFS/apex"

# NOTE: the list is only a hint; apexd (host daemon) owns the preinstalled set
# and PMS parses the paths it reports. That is why the host's apex directories
# are bound into this rootfs (see the /system_ext/apex and /system/apex binds):
# every path in this list must resolve after the pivot.
# The staged clean list was produced for the LineageOS 23.2 apex set, so it is
# only used when USE_LINEAGE_APEX_LIST=1; otherwise the host's own list is
# used, which matches what host apexd reports for any GSI.
if [ "$USE_LINEAGE_APEX_LIST" = "1" ] && [ -f "$STAGE/clean_apex_info_list.xml" ]; then
    cp "$STAGE/clean_apex_info_list.xml" "$ROOTFS/apex/apex-info-list.xml"
else
    cp -a /apex/apex-info-list.xml "$ROOTFS/apex/" 2>/dev/null || true
fi
chmod 644 "$ROOTFS/apex/apex-info-list.xml" 2>/dev/null || true
# 6.6: core APEX set — every APEX whose jars land on a boot or
# system-server classpath (guest derive_classpath output, proven
# by the 6.4 bundle's classpath dumps). These MUST be
# guest-generation: a host-served core APEX against the guest
# framework is the conscrypt/core-libart NoSuchMethodError
# (isInZygote) that killed every 6.5 zygote attempt, with the
# patches OFF (stock guest jars). Short names (com.android.
# prefix stripped); runtime/cellbroadcast/extservices stay
# non-core (not on any classpath). Used by the P8 filter log,
# mount_payload skew warnings, and the step-9 provenance log.
_APEX_CORE="art i18n adservices appsearch bt configinfrastructure conscrypt crashrecovery devicelock healthfitness ipsec media mediaprovider nfcservices npumanager ondevicepersonalization os.statsd permission profiling scheduling sdkext telephonycore tethering uprobestats uwb virt webapp wifi compos rkpd"
# 6.0 (P8): filter the apex-info list to entries that resolve in
# this guest, and strip Samsung/SEC/lifeguard entries. A list entry
# whose module path does not exist under the guest rootfs makes PMS
# chase a path that cannot resolve; vendor entries from the host
# list do not belong in a foreign guest. Header/footer lines pass
# through untouched. Best-effort: if filtering fails, the unfiltered
# list stays (boot continues; the failure is logged).
if [ -f "$ROOTFS/apex/apex-info-list.xml" ]; then
    _APEX_KEPT=0; _APEX_DROPPED=0
    _APEX_TMP="$STAGE/apex-info-list.filtered"
    if : > "$_APEX_TMP" 2>/dev/null; then
        while IFS= read -r _aline || [ -n "$_aline" ]; do
            case "$_aline" in
                *"<apex-info"*)
                    _mp="$(printf '%s' "$_aline" | sed -n 's/.*modulePath="\([^"]*\)".*/\1/p')"
                    _mn="$(printf '%s' "$_aline" | sed -n 's/.*moduleName="\([^"]*\)".*/\1/p')"
                    _ll="$(printf '%s' "$_aline" | tr 'A-Z' 'a-z')"
                    _drop=0; _drop_reason=""
                    case "$_ll" in
                        *samsung*|*lifeguard*|*com.sec.*) _drop=1; _drop_reason="samsung-sec-lifeguard" ;;
                    esac
                    if [ "$_drop" -eq 0 ] && [ -n "$_mp" ] && [ ! -e "$ROOTFS$_mp" ]; then
                        _drop=1; _drop_reason="missing-in-guest"
                    fi
                    if [ "$_drop" -eq 1 ]; then
                        _APEX_DROPPED=$((_APEX_DROPPED + 1))
                    else
                        printf '%s\n' "$_aline" >> "$_APEX_TMP"
                        _APEX_KEPT=$((_APEX_KEPT + 1))
                    fi
                    # 6.6: per-APEX filter provenance for classpath
                    # APEXes — the bare kept/dropped counts cannot
                    # prove generation consistency on-device.
                    if [ -n "$_mn" ]; then
                        case " $_APEX_CORE " in *" ${_mn#com.android.} "*)
                            if [ "$_drop" -eq 1 ]; then
                                echo "APEX_FILTER: $_mn DROPPED reason=$_drop_reason path=$_mp"
                            else
                                echo "APEX_FILTER: $_mn KEPT path=$_mp"
                            fi
                            ;;
                        esac
                    fi
                    ;;
                *) printf '%s\n' "$_aline" >> "$_APEX_TMP" ;;
            esac
        done < "$ROOTFS/apex/apex-info-list.xml"
        cp -f "$_APEX_TMP" "$ROOTFS/apex/apex-info-list.xml" 2>/dev/null || echo "APEX_FILTER_WARN: could not write filtered list (unfiltered list stays)"
        rm -f "$_APEX_TMP" 2>/dev/null || true
        echo "APEX_FILTER_6.0: kept $_APEX_KEPT entries, dropped $_APEX_DROPPED (missing in guest or Samsung/SEC/lifeguard)"
    else
        echo "APEX_FILTER_WARN: could not create temp file (unfiltered list stays)"
    fi
fi

echo "=== 8. Direct Mounting Extracted APEX Payloads ==="
mount_payload() {
    NAME="$1"
    TARGET="$2"
    IMG="$STAGE/${NAME}_payload.img"
    DEST="$ROOTFS/apex/$TARGET"
    if [ ! -f "$IMG" ]; then
        CAPEX="$ROOTFS/system/apex/com.android.${NAME}.capex"
        APEX="$ROOTFS/system/apex/com.android.${NAME}.apex"
        if [ -f "$CAPEX" ]; then
            $BB unzip -p "$CAPEX" original_apex > "$STAGE/temp_${NAME}.apex" 2>/dev/null
            $BB unzip -p "$STAGE/temp_${NAME}.apex" apex_payload.img > "$IMG" 2>/dev/null
            rm -f "$STAGE/temp_${NAME}.apex"
        elif [ -f "$APEX" ]; then
            $BB unzip -p "$APEX" apex_payload.img > "$IMG" 2>/dev/null
        fi
    fi
    [ -f "$IMG" ] || {
        # 5.9.13: previously a silent skip. A missing APEX payload can
        # break the guest boot (PMS/apexd mismatch), so name it: either
        # the guest has no such apex (benign — host binds may cover it)
        # or extraction failed (suspicious — e.g. an EROFS read error
        # while unzipping the capex, which would also explain a boot
        # crash minutes in).
        # 6.6: flattened-APEX fallback. Some GSIs ship an APEX as an
        # extracted directory under /system/apex instead of a .apex /
        # .capex file. Guest content still wins: bind the guest
        # directory onto the apex mount point so the step-9 host bind
        # cannot substitute host-generation jars. Only trusted when
        # $ROOTFS/system/apex is the guest's own dir (not a stale
        # host bind left by a previous prepare — the host bind is
        # applied after the payload mounts below).
        _FLAT="$ROOTFS/system/apex/com.android.${NAME}"
        if [ -d "$_FLAT" ] && ! mount | grep -q "$ROOTFS/system/apex "; then
            mkdir -p "$DEST"
            if $BB mount --bind "$_FLAT" "$DEST" 2>/dev/null; then
                echo "Direct bound flattened guest APEX $NAME -> $DEST"
                echo "APEX_PROVENANCE: $TARGET guest-flattened (bind $_FLAT)"
                return 0
            fi
            echo "WARNING: mount_payload $NAME: flattened guest APEX bind failed for $DEST"
        fi
        if [ -f "$CAPEX" ] || [ -f "$APEX" ]; then
            echo "WARNING: mount_payload $NAME: payload extraction failed (capex/apex present but no apex_payload.img) — APEX $TARGET will be missing"
        else
            echo "mount_payload: $NAME: no .capex/.apex in guest /system/apex — skipping (host apex binds may cover it)"
        fi
        # 6.6: generation-skew warning. A classpath APEX with no
        # guest payload is served by the step-9 host bind: host-
        # generation jars against the guest framework — exactly the
        # conscrypt/core-libart NoSuchMethodError (isInZygote) that
        # killed every 6.5 zygote attempt with the patches OFF.
        case " $_APEX_CORE " in *" $NAME "*) echo "APEX_SKEW_WARN: $TARGET has no guest payload — host bind will serve it; host-vs-guest generation skew possible" ;; esac
        return 0
    }
    if mount | grep "$DEST " | grep -q "/dev/block/dm-"; then
        $BB umount -l "$DEST" 2>/dev/null || true
        for vdir in "$ROOTFS/apex/${TARGET}"@*; do
       [ -d "$vdir" ] && $BB umount -l "$vdir" 2>/dev/null || true
        done
    fi
    if mount | grep "$DEST " | grep -q "/dev/block/loop"; then
        echo "$NAME already mounted on loop at $DEST"
        echo "APEX_PROVENANCE: $TARGET guest-payload (cached loop mount)"
        return 0
    fi
    mkdir -p "$DEST"
    $BB umount -l "$DEST" 2>/dev/null || true
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$IMG"
    # 5.9.13: previously a silent mount (failure left the APEX missing
    # with no log line). Name the failure; do not abort — host apex
    # binds may still cover this APEX.
    if $BB mount -t ext4 -o ro "$LOOP" "$DEST"; then
        echo "Direct mounted $NAME on $LOOP -> $DEST"
        echo "APEX_PROVENANCE: $TARGET guest-payload (loop $LOOP)"
    else
        echo "WARNING: mount_payload $NAME: mount failed for $DEST — APEX $TARGET will be missing"
        # 6.6: a failed payload mount falls through to the step-9
        # host bind — same generation-skew exposure as a missing
        # payload for a classpath APEX.
        case " $_APEX_CORE " in *" $NAME "*) echo "APEX_SKEW_WARN: $TARGET payload mount failed — host bind will serve it; host-vs-guest generation skew possible" ;; esac
    fi
    for vdir in "$ROOTFS/apex/${TARGET}"@*; do
        if [ -d "$vdir" ]; then
       $BB umount -l "$vdir" 2>/dev/null || true
       if $BB mount -t ext4 -o ro "$LOOP" "$vdir"; then
           echo "Direct mounted $NAME on $LOOP -> $vdir"
       else
           echo "WARNING: mount_payload $NAME: mount failed for $vdir"
       fi
        fi
    done
}

mount_payload "art" "com.android.art"
mount_payload "i18n" "com.android.i18n"
mount_payload "runtime" "com.android.runtime"
mount_payload "sdkext" "com.android.sdkext"
mount_payload "nfcservices" "com.android.nfcservices"
mount_payload "tethering" "com.android.tethering"
mount_payload "crashrecovery" "com.android.crashrecovery"
mount_payload "cellbroadcast" "com.android.cellbroadcast"
mount_payload "extservices" "com.android.extservices"
mount_payload "permission" "com.android.permission"
mount_payload "wifi" "com.android.wifi"
mount_payload "appsearch" "com.android.appsearch"
mount_payload "mediaprovider" "com.android.mediaprovider"
mount_payload "adservices" "com.android.adservices"
mount_payload "rkpd" "com.android.rkpd"
mount_payload "healthfitness" "com.android.healthfitness"
mount_payload "ondevicepersonalization" "com.android.ondevicepersonalization"
mount_payload "configinfrastructure" "com.android.configinfrastructure"
mount_payload "bt" "com.android.bt"
# 6.6: the classpath APEXes below were missing from the step-8 list,
# so their jars were served ONLY by the step-9 host binds — host
# generation against the guest framework (conscrypt A17 vs
# core-libart A16 = the 6.5 NoSuchMethodError). Guest payloads win
# for all of them now; a genuinely absent guest payload keeps the
# host fallback with a loud APEX_SKEW_WARN (see mount_payload).
mount_payload "conscrypt" "com.android.conscrypt"
mount_payload "compos" "com.android.compos"
mount_payload "devicelock" "com.android.devicelock"
mount_payload "ipsec" "com.android.ipsec"
mount_payload "media" "com.android.media"
mount_payload "npumanager" "com.android.npumanager"
mount_payload "os.statsd" "com.android.os.statsd"
mount_payload "profiling" "com.android.profiling"
mount_payload "scheduling" "com.android.scheduling"
mount_payload "telephonycore" "com.android.telephonycore"
mount_payload "uprobestats" "com.android.uprobestats"
mount_payload "uwb" "com.android.uwb"
mount_payload "virt" "com.android.virt"
mount_payload "webapp" "com.android.webapp"

# Payload extractions above used the GSI's own /system/apex files. Now that the
# images are cached, present the HOST's /system/apex to the container so the
# preinstalled paths reported by host apexd all resolve (see the note above
# about /system_ext/apex).
if [ -d /system/apex ]; then
    mkdir -p "$ROOTFS/system/apex"
    mount | grep -q "$ROOTFS/system/apex " || $BB mount --bind /system/apex "$ROOTFS/system/apex"
fi

echo "=== 9. Bind-mounting Remaining Non-Payload APEXes ==="
for a in /apex/*; do
    [ -d "$a" ] || continue
    base=$(basename "$a")
    case "$base" in
        *samsung*)
       continue
       ;;
    esac
    # Skip if already mounted
    if ! mount | grep -q "$ROOTFS/apex/$base "; then
        mkdir -p "$ROOTFS/apex/$base"
        $BB mount --bind "$a" "$ROOTFS/apex/$base" 2>/dev/null || true
        echo "Bound $base -> $ROOTFS/apex/$base"
        # 6.6: provenance for classpath APEXes. A core APEX reaching
        # this bind has no guest payload (step 8 mounts first and
        # this loop skips mounted entries) — it is host-served; the
        # APEX_SKEW_WARN from mount_payload already named it.
        # Versioned siblings (name@version) are inert for the
        # classpaths, which resolve the unversioned path — log no
        # provenance for them so a sibling bind is never misread
        # as the active APEX being host-served.
        case "$base" in
            *@*) ;;
            *)
                _short="${base#com.android.}"
                case " $_APEX_CORE " in *" $_short "*) echo "APEX_PROVENANCE: $base host-bind (no guest payload; generation-skew risk — see APEX_SKEW_WARN)" ;; esac
                ;;
        esac
    fi
done

# PermissionController patch, second pass. The same block near step 4 runs
# before the apex set is mounted, so find(1) finds nothing and Samsung's
# PermissionController stays behind. Samsung's build requires
# android.permission.RANGING, which the LineageOS 23.2 platform does not
# define, so every runtime-permission dialog dies with
#   IllegalStateException: android.permission.RANGING not defined by platform
#   -> "Permission controller keeps stopping"
# and Gallery/Phone/Calendar can never be granted anything. Bind it now that
# /apex/com.android.permission actually exists — but ONLY when the user
# enabled the patch: other GSIs may define RANGING themselves, and binding
# a Lineage-built PermissionController over them would break permissions.
if [ "$PATCH_PERMISSION_CONTROLLER" = "1" ]; then
    if [ -f "$STAGE/PermissionController_patched.apk" ]; then
        chmod 644 "$STAGE/PermissionController_patched.apk" 2>/dev/null || true
        for PERM_APK in $(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null); do
            $BB umount -l "$PERM_APK" 2>/dev/null || true
            $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK" 2>/dev/null && echo "Bound PermissionController_patched.apk (late) -> $PERM_APK" || echo "!!! WARNING: PermissionController bind failed for $PERM_APK (permission dialogs may crash, boot continues)"
        done
    else
        echo "!!! WARNING: PermissionController patch ENABLED but PermissionController_patched.apk missing from $STAGE"
        echo "!!! Samsung's PermissionController will crash every runtime-permission dialog"
        echo "!!! (android.permission.RANGING not defined by platform)"
    fi
else
    echo "PermissionController patch DISABLED by gsi_flags.conf (generic GSI mode)"
fi

# 5.9.5-SCRIPTS-START: share folder, density staging, guest-root hook.
echo "=== 5.9.5. Storage share / density / guest-root ==="
# SHARE_FOLDER=1 only: create the host shared dir if missing. The host
# media tree is already bind-mounted into the guest (see step 5), so a
# dir created under host /data/media/0 appears in the guest; the actual
# guest-side bind is done in master_inner.sh (which logs success/failure
# and never aborts boot on a bind failure).
if [ "$SHARE_FOLDER" = "1" ]; then
    mkdir -p /sdcard/GSI_Shared 2>/dev/null || mkdir -p /data/media/0/GSI_Shared 2>/dev/null || echo "SHARE_FOLDER: could not create host GSI_Shared dir (continuing)"
    [ -d /sdcard/GSI_Shared ] && echo "SHARE_FOLDER: host dir ready: /sdcard/GSI_Shared" || echo "SHARE_FOLDER: host dir ready (via /data/media/0/GSI_Shared if created)"
fi
# DENSITY_DPI: validate and stage for post-boot wm density (see the
# fix_app_dirs block above). No image file is patched here.
if [ -n "$DENSITY_DPI" ]; then
    case "$DENSITY_DPI" in
        ''|*[!0-9]*)
            echo "DENSITY: ignoring invalid DENSITY_DPI='$DENSITY_DPI' (must be a number)"
            ;;
        *)
            if [ "$DENSITY_DPI" -ge 120 ] && [ "$DENSITY_DPI" -le 640 ]; then
                printf '%s\n' "$DENSITY_DPI" > "$STAGE/density_dpi" 2>/dev/null || true
                mkdir -p "$STAGE/data/local/tmp" 2>/dev/null || true
                printf '%s\n' "$DENSITY_DPI" > "$STAGE/data/local/tmp/density_dpi" 2>/dev/null || true
                echo "DENSITY: staged $DENSITY_DPI dpi for post-boot wm density (see fix_app_dirs limits)"
            else
                echo "DENSITY: ignoring out-of-range DENSITY_DPI='$DENSITY_DPI' (120-640)"
            fi
            ;;
    esac
fi
# GUEST_ROOT=1 or guest_root.sh "on" flag: run the boot hook, which
# re-detects the host su at boot time and bind-mounts it into the
# guest. Failure here is logged, never fatal to boot. See guest_root.sh
# for the honesty note and the app-grant gap.
if [ "$GUEST_ROOT" = "1" ] || [ -f "$STAGE/guest_root.enabled" ]; then
    if [ -f "$STAGE/guest_root_hook.sh" ]; then
        /system/bin/sh "$STAGE/guest_root_hook.sh" "$STAGE" "$ROOTFS" 2>&1 || echo "GUEST_ROOT: hook failed (guest boots without guest-root bind)"
    else
        echo "GUEST_ROOT: hook script missing in $STAGE (run guest_root.sh on first); guest boots with the legacy section-6 su copy if a host su exists"
    fi
fi
# 5.9.5-SCRIPTS-END
echo "=== ALL MOUNTS PREPARED SUCCESSFULLY ==="

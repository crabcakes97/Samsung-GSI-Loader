#!/bin/bash
# Post-build verification gate for GSI Loader Samsung (added 5.9.16).
# Usage: ./verify_apk.sh <apk-path>
# The coordinator runs this after the final build, before make_dist.sh.
#
# Checks (each named; ANY miss fails loudly with a nonzero exit):
#   1. aapt2 badging: package, versionCode, versionName match expectations
#   2. apksigner verify exits 0
#   3. apksigner cert SHA-256 matches the 5.9.15 continuity cert
#   4. manifest component resolution: MainActivity activity present
#   5. expected assets present, with a SHA-256 hash list printed
#      (hashes are RECORDED, not pinned: sibling workers edit assets this
#      cycle, so pinning would false-fail. Record the printed list with
#      the release; a future release may pin it.)
#   6. no keystore material inside the APK
#
# Expectations are overridable for future releases, but the defaults are
# the 5.9.17 release values — do not change them to make a bad build pass.
#   GSI_EXPECT_PACKAGE       default com.cronch.gsiloader
#   GSI_EXPECT_VERSION_CODE  default 31
#   GSI_EXPECT_VERSION_NAME  default 5.9.17
#   GSI_EXPECT_CERT_SHA256   default 3f4ed94497375a9fbe998dd82b265f65d0c5152baf11f11da9ec0397b85f883f
#   GSI_SDK_ROOT             default /home/hatch/workspace/onelineage/android-sdk
#                            (aapt2/apksigner fall back to PATH)

APK="${1:-}"
EXPECT_PACKAGE="${GSI_EXPECT_PACKAGE:-com.cronch.gsiloader}"
EXPECT_CODE="${GSI_EXPECT_VERSION_CODE:-31}"
EXPECT_NAME="${GSI_EXPECT_VERSION_NAME:-5.9.17}"
EXPECT_CERT="${GSI_EXPECT_CERT_SHA256:-3f4ed94497375a9fbe998dd82b265f65d0c5152baf11f11da9ec0397b85f883f}"
SDK_ROOT="${GSI_SDK_ROOT:-/home/hatch/workspace/onelineage/android-sdk}"

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

if [ -z "$APK" ]; then
    echo "Usage: $0 <apk-path>" >&2
    exit 2
fi
if [ ! -f "$APK" ]; then
    echo "FAIL: APK not found: $APK" >&2
    exit 2
fi

# Resolve tools: SDK build-tools 34.0.0 first, then PATH.
if [ -x "$SDK_ROOT/build-tools/34.0.0/aapt2" ]; then
    AAPT2="$SDK_ROOT/build-tools/34.0.0/aapt2"
else
    AAPT2="$(command -v aapt2 || true)"
fi
if [ -x "$SDK_ROOT/build-tools/34.0.0/apksigner" ]; then
    APKSIGNER="$SDK_ROOT/build-tools/34.0.0/apksigner"
else
    APKSIGNER="$(command -v apksigner || true)"
fi
if [ -z "$AAPT2" ]; then echo "FAIL: aapt2 not found (set GSI_SDK_ROOT or put aapt2 on PATH)" >&2; exit 2; fi
if [ -z "$APKSIGNER" ]; then echo "FAIL: apksigner not found (set GSI_SDK_ROOT or put apksigner on PATH)" >&2; exit 2; fi
# apksigner is a launcher script that execs `java`: resolve a JDK the same
# way build_apk_linux.sh does (GSI_JDK wins, else Temurin, else apt JDK 17,
# else javac on PATH), or apksigner fails with "java: not found".
if [ -n "${GSI_JDK:-}" ]; then
    export JAVA_HOME="$GSI_JDK"
elif [ -d "/home/hatch/workspace/onelineage/jdk17" ]; then
    export JAVA_HOME="/home/hatch/workspace/onelineage/jdk17"
elif [ -d "/usr/lib/jvm/java-17-openjdk-amd64" ]; then
    export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
elif command -v javac >/dev/null 2>&1; then
    export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
fi
if [ -n "${JAVA_HOME:-}" ]; then export PATH="$JAVA_HOME/bin:$PATH"; fi
command -v unzip >/dev/null 2>&1 || { echo "FAIL: unzip not found" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: sha256sum not found" >&2; exit 2; }

echo "=== verify_apk.sh: $APK ==="
echo "Expecting package=$EXPECT_PACKAGE versionCode=$EXPECT_CODE versionName=$EXPECT_NAME"
echo "Expecting cert SHA-256=$EXPECT_CERT"

# --- 1. aapt2 badging ---
BADGING="$("$AAPT2" dump badging "$APK" 2>&1)" || { fail "aapt2 dump badging failed: $BADGING"; }
BADGE_LINE="$(printf '%s\n' "$BADGING" | grep "^package:" | head -n 1)"
echo "Badging: $BADGE_LINE"
case "$BADGE_LINE" in
    *"name='$EXPECT_PACKAGE'"*) pass "badging package = $EXPECT_PACKAGE" ;;
    *) fail "badging package mismatch (got: $BADGE_LINE)" ;;
esac
case "$BADGE_LINE" in
    *"versionCode='$EXPECT_CODE'"*) pass "badging versionCode = $EXPECT_CODE" ;;
    *) fail "badging versionCode mismatch (got: $BADGE_LINE)" ;;
esac
case "$BADGE_LINE" in
    *"versionName='$EXPECT_NAME'"*) pass "badging versionName = $EXPECT_NAME" ;;
    *) fail "badging versionName mismatch (got: $BADGE_LINE)" ;;
esac

# --- 2 + 3. apksigner verify + cert fingerprint ---
if "$APKSIGNER" verify "$APK" >/dev/null 2>&1; then
    pass "apksigner verify exit 0"
else
    fail "apksigner verify failed (nonzero exit)"
fi
CERT_LINE="$("$APKSIGNER" verify --print-certs "$APK" 2>&1 | grep -i "SHA-256 digest" | head -n 1)"
FOUND_CERT="$(printf '%s' "$CERT_LINE" | sed 's/.*: //' | tr -d ':' | tr 'A-F' 'a-f' | tr -d '[:space:]')"
echo "Signer cert SHA-256: $FOUND_CERT"
if [ "$FOUND_CERT" = "$EXPECT_CERT" ]; then
    pass "signing cert SHA-256 matches 5.9.15 continuity cert"
else
    fail "signing cert SHA-256 mismatch (got: $FOUND_CERT, want: $EXPECT_CERT) — 5.9.16 would NOT update over 5.9.15"
fi

# --- 4. manifest component resolution ---
XMLTREE="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" 2>&1)" || { fail "aapt2 dump xmltree failed"; }
if printf '%s\n' "$XMLTREE" | grep -q "MainActivity"; then
    pass "manifest contains MainActivity activity component"
else
    fail "manifest missing MainActivity activity component"
fi

# --- 5. expected assets present + hash list (recorded, not pinned) ---
echo "--- asset hash list (recorded for the release; presence is gated, hashes are not pinned) ---"
for asset in install_image.sh switch_to_gsi.sh master_prepare.sh master_inner.sh \
    return_to_oneui.sh guards.sh boot_watchdog.sh boot_diagnostics.sh \
    pstore_check.sh preflight_host.sh backup_slot.sh snapshot_slot.sh \
    rollback_slot.sh verify_backup.sh guest_root.sh guest_root_shell.sh \
    inspect_image.sh battery_guard.sh check_slot_guard.sh \
    framework_patched.jar services_patched.jar PermissionController_patched.apk \
    clean_apex_info_list.xml zygote_exec simg2img 7zz; do
    if unzip -l "$APK" "assets/$asset" 2>/dev/null | grep -q "assets/$asset"; then
        HASH="$(unzip -p "$APK" "assets/$asset" 2>/dev/null | sha256sum | cut -d' ' -f1)"
        echo "  assets/$asset  sha256=$HASH"
    else
        fail "missing asset in APK: assets/$asset"
    fi
done

# --- 6. no keystore material inside the APK ---
if unzip -l "$APK" 2>/dev/null | grep -E "\.keystore|keystore/" | grep -v "^$" >/dev/null; then
    fail "APK contains keystore material (must never ship a keystore)"
else
    pass "no keystore material in APK"
fi

echo "=== verify_apk.sh result: $FAILURES failure(s) ==="
if [ "$FAILURES" -ne 0 ]; then
    echo "GATE FAILED: do not ship this APK." >&2
    exit 1
fi
echo "GATE PASSED: $APK"
exit 0

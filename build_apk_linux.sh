#!/bin/bash
# Linux adaptation of build_apk.sh (macOS original, untouched).
# Same 7 steps; only paths/toolchain locations changed.
#
# 5.9.16: paths are parameterized via environment variables with defaults
# that resolve to the current VM layout, so an unset environment builds
# exactly as before. Toolchain behavior is UNCHANGED: JDK 17, aapt2,
# platform android-34, javac -encoding UTF-8 -source 1.8 -target 1.8, d8,
# zipalign, apksigner.
#
#   GSI_PROJECT_DIR  tree root (default: directory containing this script)
#   GSI_SDK_ROOT     Android SDK root (default: /home/hatch/workspace/onelineage/android-sdk)
#   GSI_JDK          JDK 17 home (default: /home/hatch/workspace/onelineage/jdk17
#                    if present, else apt JDK 17, else javac on PATH)
#   GSI_OUT_APK      output APK path (default: $GSI_PROJECT_DIR/../GSI-Loader-Samsung.apk)
#   GSI_KEYSTORE     signing keystore (default: $GSI_PROJECT_DIR/../gsi-loader.keystore)
#
# KEYSTORE RULE (5.9.16): the keystore lives OUTSIDE the tree at
# ~/workspace/onelineage-generic/gsi-loader.keystore and MUST keep cert
# SHA-256 3f4ed94497375a9fbe998dd82b265f65d0c5152baf11f11da9ec0397b85f883f
# so 5.9.16 updates over 5.9.15. This script NEVER auto-generates a
# keystore: if GSI_KEYSTORE points at a missing file it FAILS LOUDLY,
# because a fresh keystore would silently change the signing cert and
# break update-over-install. Never add a keystore to a source zip
# (see make_dist.sh, which scans for and refuses keystore material).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${GSI_PROJECT_DIR:-$SCRIPT_DIR}"
SDK_ROOT="${GSI_SDK_ROOT:-/home/hatch/workspace/onelineage/android-sdk}"
OUT_APK="${GSI_OUT_APK:-$PROJECT_DIR/../GSI-Loader-Samsung.apk}"
KEYSTORE="${GSI_KEYSTORE:-$PROJECT_DIR/../gsi-loader.keystore}"

# JDK 17: explicit GSI_JDK wins; else Temurin tarball, else apt JDK, else PATH.
if [ -n "${GSI_JDK:-}" ]; then
    export JAVA_HOME="$GSI_JDK"
elif [ -d "/home/hatch/workspace/onelineage/jdk17" ]; then
    export JAVA_HOME="/home/hatch/workspace/onelineage/jdk17"
elif [ -d "/usr/lib/jvm/java-17-openjdk-amd64" ]; then
    export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
elif command -v javac >/dev/null 2>&1; then
    export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
fi
export PATH="$JAVA_HOME/bin:$PATH"

BUILD_DIR="$PROJECT_DIR/build"
SDK_TOOLS="$SDK_ROOT/build-tools/34.0.0"
PLATFORM_JAR="$SDK_ROOT/platforms/android-34/android.jar"

echo "=== build config ==="
echo "PROJECT_DIR: $PROJECT_DIR"
echo "SDK_ROOT:    $SDK_ROOT"
echo "JAVA_HOME:   $JAVA_HOME"
echo "OUT_APK:     $OUT_APK"
echo "KEYSTORE:    $KEYSTORE"

# Fail loudly on a missing keystore — never auto-generate one (see header).
if [ ! -f "$KEYSTORE" ]; then
    echo "ERROR: signing keystore not found: $KEYSTORE" >&2
    echo "Refusing to auto-generate a replacement: a new keystore would change" >&2
    echo "the signing cert (must stay SHA-256 3f4ed944...) and break" >&2
    echo "update-over-install over 5.9.15. Set GSI_KEYSTORE to the relocated" >&2
    echo "keystore (~/workspace/onelineage-generic/gsi-loader.keystore)." >&2
    exit 1
fi

echo "=== 1. Cleaning & preparing build directories ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex"

cd "$PROJECT_DIR"

echo "=== 2. Compiling resources with aapt2 ==="
"$SDK_TOOLS/aapt2" compile --dir res -o "$BUILD_DIR/compiled_res.zip"

echo "=== 3. Linking resources with aapt2 ==="
"$SDK_TOOLS/aapt2" link \
    -I "$PLATFORM_JAR" \
    --manifest AndroidManifest.xml \
    -o "$BUILD_DIR/base.apk" \
    --java "$BUILD_DIR/gen" \
    "$BUILD_DIR/compiled_res.zip" \
    -A assets

echo "=== 4. Compiling Java sources ==="
# -encoding UTF-8: MainActivity.java contains non-ASCII characters (ellipsis,
# curly quotes); this VM's default charset is US-ASCII, unlike macOS (UTF-8).
# Build-plumbing flag only; sources untouched.
javac -encoding UTF-8 -source 1.8 -target 1.8 \
    -cp "$PLATFORM_JAR" \
    -d "$BUILD_DIR/classes" \
    src/com/cronch/gsiloader/MainActivity.java \
    "$BUILD_DIR/gen/com/cronch/gsiloader/R.java"

echo "=== 5. Generating Dalvik Executable (classes.dex) with d8 ==="
"$SDK_TOOLS/d8" \
    --lib "$PLATFORM_JAR" \
    --output "$BUILD_DIR/dex" \
    "$BUILD_DIR/classes/com/cronch/gsiloader"/*.class

echo "=== 6. Packaging classes.dex into APK ==="
cd "$BUILD_DIR/dex"
zip -u "$BUILD_DIR/base.apk" classes.dex
cd "$PROJECT_DIR"

echo "=== 7. Aligning APK with zipalign ==="
"$SDK_TOOLS/zipalign" -v -p 4 "$BUILD_DIR/base.apk" "$BUILD_DIR/aligned.apk"

"$SDK_TOOLS/apksigner" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --ks-key-alias androiddebugkey \
    --key-pass pass:android \
    --out "$OUT_APK" \
    "$BUILD_DIR/aligned.apk"

echo "=== BUILD SUCCESSFUL ==="
echo "Output APK: $OUT_APK"
ls -la "$OUT_APK"
echo "Next: run ./verify_apk.sh \"$OUT_APK\" (post-build gate), then ./make_dist.sh \"$OUT_APK\"."

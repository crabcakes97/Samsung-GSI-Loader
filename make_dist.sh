#!/bin/bash
# Delivery-zip builder for GSI Loader Samsung (added 5.9.16).
# Usage: ./make_dist.sh <built-apk-path> [output-zip-path]
# Run AFTER ./verify_apk.sh passes on the same APK.
#
# Layout of the zip:
#   GSI-Loader-Samsung.apk            (top level, the built APK)
#   GSI-Loader-Samsung-source/        (tree source needed to rebuild)
#     AndroidManifest.xml, build_apk_linux.sh, build_apk.sh,
#     verify_apk.sh, make_dist.sh, src/, res/, assets/,
#     ARCHITECTURE.md, PATCHES.md, TROUBLESHOOTING.md, README.md
#
# NEVER included (enforced twice: by exclusion at staging time, and by a
# post-zip scan that fails the run if any slip through):
#   keystores (*.keystore, any keystore/ directory), build/ output,
#   .git metadata, probe-av/ (separate test app, not app source).
# The signing keystore lives OUTSIDE the tree
# (~/workspace/onelineage-generic/gsi-loader.keystore) and is never staged.
# Prints byte size + SHA-256 of the finished zip.

set -e

APK="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${GSI_PROJECT_DIR:-$SCRIPT_DIR}"
VERSION="${GSI_DIST_VERSION:-5.9.18}"
OUT_ZIP="${2:-$PROJECT_DIR/../GSI-Loader-Samsung-${VERSION}-dist.zip}"

if [ -z "$APK" ]; then
    echo "Usage: $0 <built-apk-path> [output-zip-path]" >&2
    exit 2
fi
if [ ! -f "$APK" ]; then
    echo "ERROR: APK not found: $APK" >&2
    exit 2
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
SRC_DIR="$STAGE/GSI-Loader-Samsung-source"
mkdir -p "$SRC_DIR"

echo "=== staging source (keystore/build/.git excluded) ==="
cp "$PROJECT_DIR/AndroidManifest.xml" "$SRC_DIR/"
cp "$PROJECT_DIR/build_apk_linux.sh" "$SRC_DIR/"
cp "$PROJECT_DIR/build_apk.sh" "$SRC_DIR/"
cp "$PROJECT_DIR/verify_apk.sh" "$SRC_DIR/"
cp "$PROJECT_DIR/make_dist.sh" "$SRC_DIR/"
cp -r "$PROJECT_DIR/src" "$SRC_DIR/"
cp -r "$PROJECT_DIR/res" "$SRC_DIR/"
cp -r "$PROJECT_DIR/assets" "$SRC_DIR/"
for doc in ARCHITECTURE.md PATCHES.md TROUBLESHOOTING.md README.md; do
    if [ -f "$PROJECT_DIR/$doc" ]; then
        cp "$PROJECT_DIR/$doc" "$SRC_DIR/"
    else
        echo "WARNING: doc missing from tree, skipped: $doc" >&2
    fi
done
cp "$APK" "$STAGE/GSI-Loader-Samsung.apk"

# Exclusion enforcement, pass 1: nothing keystore/build/.git may be staged.
# (Staging above copies only listed paths, so any hit here is a real bug.)
if find "$STAGE" \( -name "*.keystore" -o -name "keystore" -o -name "build" -o -name ".git" \) -print -quit | grep -q .; then
    echo "ERROR: forbidden material staged (keystore/build/.git) — refusing to zip." >&2
    find "$STAGE" \( -name "*.keystore" -o -name "keystore" -o -name "build" -o -name ".git" \) -print >&2
    exit 1
fi

echo "=== building zip: $OUT_ZIP ==="
rm -f "$OUT_ZIP"
(cd "$STAGE" && zip -r -q "$OUT_ZIP" "GSI-Loader-Samsung.apk" "GSI-Loader-Samsung-source")

# Exclusion enforcement, pass 2: post-zip scan — fail if any keystore
# entry is present, even if staging somehow let it through.
if unzip -l "$OUT_ZIP" | grep -E "\.keystore|keystore/" | grep -v "^$" >/dev/null; then
    echo "ERROR: post-zip scan found keystore material in $OUT_ZIP — deleting it." >&2
    unzip -l "$OUT_ZIP" | grep -E "\.keystore|keystore/" >&2
    rm -f "$OUT_ZIP"
    exit 1
fi
if unzip -l "$OUT_ZIP" | grep -E "(^|/)build/|(^|/)\.git/" >/dev/null; then
    echo "ERROR: post-zip scan found build/ or .git material in $OUT_ZIP — deleting it." >&2
    rm -f "$OUT_ZIP"
    exit 1
fi

SIZE="$(stat -c%s "$OUT_ZIP")"
HASH="$(sha256sum "$OUT_ZIP" | cut -d' ' -f1)"
echo "=== DIST READY ==="
echo "Zip:    $OUT_ZIP"
echo "Size:   $SIZE bytes"
echo "SHA-256: $HASH"
unzip -l "$OUT_ZIP" | head -n 20

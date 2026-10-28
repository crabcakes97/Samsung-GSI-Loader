#!/bin/bash
set -e
export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
export PATH="$JAVA_HOME/bin:$PATH"

P="/Users/waffles/.gemini/antigravity/scratch/LineageSwitcher/probe-av"
B="$P/build"
TOOLS="/Users/waffles/Library/Android/sdk/build-tools/34.0.0"
AJ="/Users/waffles/Library/Android/sdk/platforms/android-34/android.jar"
KS="/Users/waffles/.gemini/antigravity/scratch/LineageSwitcher/keystore/debug.keystore"

rm -rf "$B"; mkdir -p "$B/classes" "$B/dex"
cd "$P"
"$TOOLS/aapt2" link -I "$AJ" --manifest AndroidManifest.xml -o "$B/base.apk"
javac -source 1.8 -target 1.8 -cp "$AJ" -d "$B/classes" src/com/test/avprobe/MainActivity.java
"$TOOLS/d8" --lib "$AJ" --output "$B/dex" $(find "$B/classes" -name '*.class')
(cd "$B/dex" && zip -q -u "$B/base.apk" classes.dex)
"$TOOLS/zipalign" -f -p 4 "$B/base.apk" "$B/aligned.apk"
"$TOOLS/apksigner" sign --ks "$KS" --ks-pass pass:android --ks-key-alias androiddebugkey \
    --key-pass pass:android --out "$P/avprobe.apk" "$B/aligned.apk"
echo "built $P/avprobe.apk"
ls -l "$P/avprobe.apk"

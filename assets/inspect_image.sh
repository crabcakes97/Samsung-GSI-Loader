#!/system/bin/sh
# inspect_image.sh — read-only report on a GSI file. Changes nothing.
# Usage: inspect_image.sh <file> [7zz_path]
# Prints: path, size (bytes + MB), format (sparse/ext4/erofs/unknown),
# and for archives the contained entries (via 7zz l, capped).
# 5.9.10: byte sizes are only printed or converted to MB via awk —
# no shell integer test or $(( )) ever operates on a raw byte size
# (the phone's 32-bit test wraps sizes over 2 GiB).
FILE="$1"
SEVENZZ="$2"
[ -n "$FILE" ] || { echo "INSPECT_ERROR: no file given"; exit 1; }
[ -f "$FILE" ] || { echo "INSPECT_ERROR: not a file: $FILE"; exit 1; }

SIZE=$(stat -c %s "$FILE" 2>/dev/null || echo 0)
case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
SIZE_MB=$(awk -v s="$SIZE" 'BEGIN{printf "%d", s/1048576}' 2>/dev/null || echo 0)
echo "INSPECT: file=$FILE"
echo "INSPECT: size=$SIZE bytes ($SIZE_MB MB)"
if [ ! -s "$FILE" ]; then
    echo "INSPECT: format=empty (0 bytes)"
    exit 0
fi

MAGIC0=$(od -An -tx1 -N4 "$FILE" 2>/dev/null | tr -d ' \n')
MAGIC_EXT=$(dd if="$FILE" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
MAGIC_EROFS=$(dd if="$FILE" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
FORMAT="unknown"
[ "$MAGIC0" = "3aff26ed" ] && FORMAT="sparse (Android sparse image — needs simg2img conversion at install)"
[ "$MAGIC_EXT" = "53ef" ] && FORMAT="ext4 (read-write filesystem)"
[ "$MAGIC_EROFS" = "e2e1f5e0" ] && FORMAT="erofs (read-only filesystem)"
echo "INSPECT: format=$FORMAT"

case "$FILE" in
    *.7z|*.zip|*.xz|*.gz|*.tgz|*.tar)
        echo "INSPECT: archive contents:"
        if [ -n "$SEVENZZ" ] && [ -x "$SEVENZZ" ]; then
            "$SEVENZZ" l "$FILE" 2>&1 | head -n 30
        else
            echo "INSPECT: (7zz not available — contents listing skipped)"
        fi
        ;;
esac
exit 0

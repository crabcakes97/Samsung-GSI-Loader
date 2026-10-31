#!/system/bin/sh
# 6.0 (P11) — One UI host-layout backup, run by switch_to_gsi.sh
# BEFORE the takeover stops anything. Backs up launcher databases +
# shared_prefs, appwidgets.xml, Quick Settings tiles, and the
# launcher UID into /data/local/tmp/gsi_host_backup.
#
# This dir is deliberately SEPARATE from the legacy
# /data/local/tmp/lineage_backups dir (whose contents
# return_to_oneui.sh restores into launcher databases): mixing the
# extras in there would make the legacy restore copy a shared_prefs
# subdirectory into databases/. return_to_oneui.sh restores the
# extras from this dir in its launcher section.
#
# Best-effort throughout: every step tolerates a missing source,
# and the script never exits nonzero over a backup miss — a failed
# backup must not block the guest boot.
BACKUP_DIR="/data/local/tmp/gsi_host_backup"
mkdir -p "$BACKUP_DIR" || exit 0
LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_DATA="/data/user/0/$LAUNCHER_PKG"

if [ -d "$LAUNCHER_DATA/databases" ]; then
    mkdir -p "$BACKUP_DIR/databases"
    cp -a "$LAUNCHER_DATA/databases/"* "$BACKUP_DIR/databases/" 2>/dev/null || true
    echo "  Launcher databases backed up."
fi
if [ -d "$LAUNCHER_DATA/shared_prefs" ]; then
    mkdir -p "$BACKUP_DIR/shared_prefs"
    cp -a "$LAUNCHER_DATA/shared_prefs/"* "$BACKUP_DIR/shared_prefs/" 2>/dev/null || true
    echo "  Launcher shared_prefs backed up."
fi
if [ -f /data/system/users/0/appwidgets.xml ]; then
    cp -f /data/system/users/0/appwidgets.xml "$BACKUP_DIR/appwidgets.xml" 2>/dev/null || true
    echo "  /data/system/users/0/appwidgets.xml backed up."
fi
_QS_TILES="$(settings get secure sysui_qs_tiles 2>/dev/null)"
if [ -n "$_QS_TILES" ] && [ "$_QS_TILES" != "null" ]; then
    printf '%s' "$_QS_TILES" > "$BACKUP_DIR/sysui_qs_tiles.txt" 2>/dev/null || true
    echo "  sysui_qs_tiles saved."
fi
_LAUNCHER_UID="$(grep "^$LAUNCHER_PKG " /data/system/packages.list 2>/dev/null | awk '{print $2}')"
[ -n "$_LAUNCHER_UID" ] || _LAUNCHER_UID="$(stat -c %u "$LAUNCHER_DATA" 2>/dev/null || echo "")"
if [ -n "$_LAUNCHER_UID" ]; then
    printf '%s' "$_LAUNCHER_UID" > "$BACKUP_DIR/launcher_uid.txt" 2>/dev/null || true
    echo "  Launcher UID recorded: $_LAUNCHER_UID"
fi
chmod 700 "$BACKUP_DIR" 2>/dev/null || true
echo "HOST_BACKUP_6.0: One UI layout backup done -> $BACKUP_DIR"

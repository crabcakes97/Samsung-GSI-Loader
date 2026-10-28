#!/system/bin/sh
# battery_guard.sh <minPct>  (5.9.5, POSIX sh)
# Reads the battery level (dumpsys battery first, sysfs fallback) and
# prints "BATTERY_OK <pct>" or "BATTERY_LOW <pct>". Exit 0 on OK, 1 on
# LOW. If no level can be read at all, it prints nothing claiming a
# level: it reports BATTERY_ERROR to stderr and exits 1.
# Test override (VM synthetic tests only): GSI_BATTERY_CAPACITY_FILE
# points at a file containing a plain percentage; on device it is unset
# and the dumpsys/sysfs paths below are used.
MIN="$1"
case "$MIN" in
    ''|*[!0-9]*) echo "BATTERY_ERROR: minPct must be a number 0-100" >&2; exit 1 ;;
esac
[ "$MIN" -ge 0 ] && [ "$MIN" -le 100 ] || { echo "BATTERY_ERROR: minPct out of range 0-100" >&2; exit 1; }
PCT=""
if [ -n "$GSI_BATTERY_CAPACITY_FILE" ] && [ -f "$GSI_BATTERY_CAPACITY_FILE" ]; then
    PCT="$(tr -d ' \n\r' < "$GSI_BATTERY_CAPACITY_FILE" 2>/dev/null)"
fi
if [ -z "$PCT" ] && command -v dumpsys >/dev/null 2>&1; then
    PCT="$(dumpsys battery 2>/dev/null | awk -F: '/^[[:space:]]*level:/ {gsub(/ /,"",$2); print $2; exit}')"
fi
if [ -z "$PCT" ]; then
    for _f in /sys/class/power_supply/battery/capacity /sys/class/power_supply/*/capacity; do
        [ -f "$_f" ] || continue
        PCT="$(tr -d ' \n\r' < "$_f" 2>/dev/null)"
        [ -n "$PCT" ] && break
    done
fi
case "$PCT" in
    ''|*[!0-9]*) echo "BATTERY_ERROR: could not read battery level" >&2; exit 1 ;;
esac
if [ "$PCT" -ge "$MIN" ]; then
    echo "BATTERY_OK $PCT"
    exit 0
else
    echo "BATTERY_LOW $PCT"
    exit 1
fi

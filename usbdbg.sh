#!/system/bin/sh
# v116: capture USB/adb state to /data so it survives the kmsg ring buffer.
#
# The kmsg buffer is flooded by logd's "Skipping entries from slow reader"
# lines (13k+ per boot), which evicts the whole 0-176 s boot window before
# recovery can read /proc/last_kmsg. This script writes snapshots to
# /data/usbdbg/ instead.
#
# Usage: usbdbg.sh <tag>
#   tags: pfsd | adbd | ffs | state | bootdone

TAG="${1:-unknown}"
OUT=/data/usbdbg
mkdir -p "$OUT" 2>/dev/null

LOG="$OUT/$TAG.log"
{
    echo "===== TAG=$TAG TS=$(date +%s) ====="
    echo "--- props ---"
    getprop 2>/dev/null | grep -E 'usb|adb'
    echo "--- sys.usb.state ---"
    getprop sys.usb.state
    echo "--- UDC available ---"
    ls /sys/class/udc 2>/dev/null
    echo "--- g1/UDC bound ---"
    cat /config/usb_gadget/g1/UDC 2>/dev/null
    echo "--- gadget functions ---"
    ls /config/usb_gadget/g1/functions 2>/dev/null
    echo "--- configs/b.1 ---"
    ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null
    echo "--- ffs mounts ---"
    mount 2>/dev/null | grep usb-ffs
    echo "--- /dev/usb-ffs/adb ---"
    ls -l /dev/usb-ffs/adb 2>/dev/null
    echo "--- adbd process ---"
    ps -A 2>/dev/null | grep -E 'adbd|adbd_socket'
    echo "--- end ---"
} > "$LOG" 2>&1

# Keep a short history too, one line per event.
echo "$TAG ts=$(date +%s) state=$(getprop sys.usb.state) udc=$(cat /config/usb_gadget/g1/UDC 2>/dev/null) ffsready=$(getprop sys.usb.ffs.ready) adbd=$(getprop init.svc.adbd)" >> "$OUT/history.log" 2>&1

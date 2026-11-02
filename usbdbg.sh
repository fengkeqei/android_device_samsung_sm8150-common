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

# The boot5/late probes are started from "on boot"; sleep here so the
# snapshot lands after init.qcom.usb.rc has built the gadget and adbd has
# had time to open ep0.
case "$TAG" in
    boot5) sleep 8 ;;
    late)  sleep 25 ;;
esac

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
    echo "--- logd readers (who holds logdr socket) ---"
    # v119: the previous implementation walked /proc/*/fd/* and readlink()ed
    # every descriptor. Each readlink on another process is audited, which
    # produced 9468 audit lines in one boot and evicted the first 19 s of
    # kernel log -- the probe became the new flood. Use the socket table
    # instead: /proc/net/unix lists logdr holders with pid, and 'ls -l
    # /proc/<pid>/fd' is a single opendir+readdir per pid rather than a
    # per-fd readlink.
    echo "-- logdr/unix sockets --"
    cat /proc/net/unix 2>/dev/null | grep -E 'logdr|logd|logdw' | head -10
    echo "-- holders --"
    for pid in $(cat /proc/net/unix 2>/dev/null | grep -E 'logdr' | awk '{print $NF}' | sort -u); do
        [ -d "/proc/$pid" ] && echo "pid=$pid comm=$(cat /proc/$pid/comm 2>/dev/null)"
    done
    echo "--- logcatd / logcat processes ---"
    ps -A 2>/dev/null | grep -E 'logcatd|logcat'
    echo "--- logd threads ---"
    ps -AT 2>/dev/null | grep -E 'logd' | head -10
    echo "--- functionfs ep state ---"
    # ep0 exists once init mounts functionfs; ep1/ep2 are created by the
    # kernel only after adbd successfully writes the descriptors to ep0.
    # Seeing ep0 without ep1/ep2 means the descriptor write failed, which
    # also means sys.usb.ffs.ready was never set.
    ls -l /dev/usb-ffs/adb/ 2>/dev/null
    echo "-- ep0 size (0 = no descriptors written yet) --"
    stat -c '%s %n' /dev/usb-ffs/adb/ep0 2>/dev/null
    echo "-- adbd fd count (single readdir, no per-fd readlink: that is audited) --"
    ls /proc/$(pidof adbd 2>/dev/null)/fd 2>/dev/null | wc -l
    echo "-- adbd cmdline --"
    tr '\0' ' ' < /proc/$(pidof adbd 2>/dev/null)/cmdline 2>/dev/null
    echo
    echo "--- end ---"
} > "$LOG" 2>&1

# Keep a short history too, one line per event.
echo "$TAG ts=$(date +%s) state=$(getprop sys.usb.state) udc=$(cat /config/usb_gadget/g1/UDC 2>/dev/null) ffsready=$(getprop sys.usb.ffs.ready) adbd=$(getprop init.svc.adbd)" >> "$OUT/history.log" 2>&1

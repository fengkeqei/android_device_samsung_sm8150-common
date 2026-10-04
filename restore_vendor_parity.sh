#!/usr/bin/env bash
#
# restore_vendor_parity.sh — restore files from a known-good vendor image
# (seed) into a target raw ext4 image, preserving mode/uid/gid/SELinux label.
#
# Used to bring the freshly built vendor.img back to parity with the previously
# booted vendor: the rebuild dropped ~105 stock files (pruned blob list +
# packaging anomaly), whose absence makes a dozen vendor HALs crash-loop and
# trips RescueParty before boot completes.
#
# Usage: restore_vendor_parity.sh <target.raw> <remove_list> <restore_list>
#
set -euo pipefail

OLD=${SEED_IMG:-/home/dev/Projects/vendor_dev_backup_before_1002e.raw}
IMG=${1:?usage: restore_vendor_parity.sh target.raw remove_list restore_list}
REMOVE_LIST=${2:?missing remove list}
RESTORE_LIST=${3:?missing restore list}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -f "$OLD" ] || { echo "seed image not found: $OLD" >&2; exit 1; }
[ -f "$IMG" ] || { echo "target image not found: $IMG" >&2; exit 1; }

has_inode() {  # $1=img $2=path
    debugfs -R "stat $2" "$1" 2>/dev/null | head -1 | grep -q "Inode"
}

# Old image's NUL-terminated SELinux label for $1 (empty if none).
old_label() {
    debugfs -R "ea_get $1 security.selinux" "$OLD" 2>/dev/null \
        | sed -n 's/.*= "\(.*\)"$/\1/p' | tail -1 | printf '%b' "$(cat)"
}

set_label() {  # $1=path  (label bytes on stdin via $2 file)
    debugfs -w -R "ea_set -f $2 $1 security.selinux" "$IMG" >/dev/null 2>&1 || true
}

mkdir_p() {  # $1=path inside image (dirs only)
    local cur=""
    for d in ${1//// }; do
        cur="$cur/$d"
        if ! has_inode "$IMG" "$cur"; then
            debugfs -w -R "mkdir $cur" "$IMG" >/dev/null 2>&1 || true
            debugfs -w -R "sif $cur mode 040755" "$IMG" >/dev/null 2>&1 || true
            debugfs -w -R "sif $cur uid 0" "$IMG" >/dev/null 2>&1 || true
            debugfs -w -R "sif $cur gid 0" "$IMG" >/dev/null 2>&1 || true
            printf 'u:object_r:vendor_file:s0\0' > "$TMP/lbl.bin"
            set_label "$cur" "$TMP/lbl.bin"
        fi
    done
}

# ---- removals (newly enabled services that crash-loop) ----
nrm=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in \#*) continue;; esac
    if has_inode "$IMG" "$p"; then
        debugfs -w -R "rm $p" "$IMG" >/dev/null 2>&1 || true
        echo "removed $p"
        nrm=$((nrm+1))
    fi
done < "$REMOVE_LIST"
echo "removals: $nrm"

# ---- restores ----
nres=0; nskip=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in \#*) continue;; esac
    if ! has_inode "$OLD" "$p"; then
        echo "WARN seed lacks $p" >&2; continue
    fi
    # parent dir
    parent=$(dirname "$p")
    [ "$parent" = "/" ] || mkdir_p "$parent"
    # dump from seed
    if ! debugfs -R "dump $p $TMP/blob" "$OLD" >/dev/null 2>&1; then
        echo "WARN dump failed $p" >&2; continue
    fi
    has_inode "$IMG" "$p" && debugfs -w -R "rm $p" "$IMG" >/dev/null 2>&1 || true
    debugfs -w -R "write $TMP/blob $p" "$IMG" >/dev/null 2>&1 || { echo "WARN write failed $p" >&2; continue; }
    rm -f "$TMP/blob"
    # metadata from seed
    stat_out=$(debugfs -R "stat $p" "$OLD" 2>/dev/null || true)
    # debugfs stat prints perms only (e.g. "Mode:  0755", no S_IF* bits).
    # Prefix with S_IFREG (0100) after stripping the leading zero: building
    # "0100" + "0755" yields the invalid 9-digit "01000755", sif fails
    # silently and executables keep the 0644 default -> init EACCES/127 on
    # every restored binary (Round 67).
    mode=$(sed -n 's/.*Mode: *\([0-7]*\).*/\1/p' <<<"$stat_out" | head -1)
    ug=$(sed -n 's/^User: *\([0-9]*\) *Group: *\([0-9]*\).*/\1 \2/p' <<<"$stat_out" | head -1)
    uid=${ug%% *}; gid=${ug##* }
    [ -n "$mode" ] && debugfs -w -R "sif $p mode 0100${mode#0}" "$IMG" >/dev/null 2>&1 || true
    [ -n "$uid" ] && debugfs -w -R "sif $p uid $uid" "$IMG" >/dev/null 2>&1 || true
    [ -n "$gid" ] && debugfs -w -R "sif $p gid $gid" "$IMG" >/dev/null 2>&1 || true
    lbl=$(old_label "$p")
    if [ -n "$lbl" ]; then
        printf '%s\0' "$lbl" > "$TMP/lbl.bin"
        set_label "$p" "$TMP/lbl.bin"
    fi
    nres=$((nres+1))
done < "$RESTORE_LIST"
echo "restored: $nres"
echo "done -> $IMG"

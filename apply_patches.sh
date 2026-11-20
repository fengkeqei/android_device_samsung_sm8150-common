#!/bin/bash
#
# Replay the Avium beyond1q modifications that live outside the device tree.
#
# The device tree (device/samsung/beyond1q, device/samsung/sm8150-common,
# vendor/samsung/sm8150-common) is the primary carrier for this port's fixes:
# those are plain source files, they survive a `repo sync`, and a clean
# `mka bacon` reproduces them. Everything else this port needed had to be
# edited in place inside upstream projects -- system/sepolicy,
# frameworks/base, hardware/interfaces and so on -- and a `repo sync` silently
# reverts all of it.
#
# patches/ holds one `git diff` per project, exported from the working tree.
# This script applies them. It is idempotent: already-applied patches are
# skipped, and a patch that no longer applies cleanly is reported instead of
# being forced through.
#
# Usage:
#   device/samsung/sm8150-common/apply_patches.sh [--check] [--regen]
#
#   (no args)   apply every patch that is not yet applied
#   --check     report status only, change nothing (exit 1 if any is missing)
#   --regen     re-export patches/ from the current working tree
#
# Run it after `repo sync` and before `mka bacon`.
#
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "$HERE/../../.." && pwd)"
PATCHES="$HERE/patches"

# Projects to manage. A patch file is <project path with / -> _>.patch.
PROJECTS=(
    system/sepolicy
    frameworks/base
    frameworks/av
    frameworks/native
    frameworks/opt/telephony
    hardware/interfaces
    hardware/samsung
    hardware/ril
    hardware/lineage/interfaces
    hardware/qcom-caf/wlan
    hardware/qcom/sm8150/gps
    packages/apps/CarrierConfig
    packages/modules/ImsMedia
    packages/modules/ImsStack
    packages/modules/Bluetooth
    packages/modules/Connectivity
    packages/modules/Wifi
    packages/modules/common
    system/core
    system/vold
    system/security
    system/libbase
    system/logging
    system/extras
    external/boringssl
    external/webrtc
    external/wpa_supplicant_8
    device/qcom/sepolicy_vndr/legacy-um
    device/samsung_slsi/sepolicy
    vendor/qcom/opensource/data-ipa-cfg-mgr-legacy-um
    vendor/qcom/opensource/power
    prebuilts/r8
    build/make
    kernel/samsung/sm8150
)

patch_for() { echo "$PATCHES/$(echo "$1" | tr '/' '_').patch"; }

# A patch that only flips a file mode (no hunks) cannot be probed with
# `git apply --check`: git is lenient about mode changes in BOTH directions, so
# a mode-only patch reports "applies" on an already-patched tree and
# "reverse-applies" on a clean one. Compare the actual mode instead.
# Echoes "applied", "missing", or "" when the patch is not mode-only.
mode_only_state() {
    local dir="$1" file="$2"
    local old new target cur
    old=$(sed -n 's/^old mode \([0-7]\{6\}\)$/\1/p' "$file")
    new=$(sed -n 's/^new mode \([0-7]\{6\}\)$/\1/p' "$file")
    [ -n "$old" ] && [ -n "$new" ] || return 0
    # Any hunk content means the patch is not purely a mode flip.
    if grep -q '^@@' "$file"; then
        return 0
    fi
    target=$(sed -n 's|^diff --git a/.* b/\(.*\)$|\1|p' "$file" | head -1)
    [ -n "$target" ] || return 0
    [ -e "$dir/$target" ] || { echo missing; return 0; }
    cur=$(stat -c '%a' "$dir/$target")
    # git modes are 6-digit (100755); stat gives octal without the file-type
    # prefix, so compare the low three digits.
    if [ "$cur" = "${new: -3}" ]; then
        echo applied
    elif [ "$cur" = "${old: -3}" ]; then
        echo missing
    fi
    return 0
}

MODE=apply
case "${1:-}" in
    --check) MODE=check ;;
    --regen) MODE=regen ;;
    "") ;;
    *) echo "usage: $0 [--check|--regen]" >&2; exit 2 ;;
esac

if [ "$MODE" = regen ]; then
    mkdir -p "$PATCHES"
    for p in "${PROJECTS[@]}"; do
        [ -d "$TREE/$p/.git" ] || continue
        out="$(patch_for "$p")"
        # New files matter as much as edits: several bring-up fixes add whole
        # files (audio legacy impls, avium rc/xml, shim sources). Plain
        # `git diff` ignores untracked paths, so a tree that only ever gained
        # files would export an empty patch and silently lose them on the next
        # `repo sync`. Stage intent-to-add first so they show up as additions.
        git -C "$TREE/$p" add -N . >/dev/null 2>&1 || true
        if git -C "$TREE/$p" diff --quiet 2>/dev/null; then
            git -C "$TREE/$p" reset -q >/dev/null 2>&1 || true
            continue
        fi
        # Binaries cannot round-trip through a patch: git writes only
        # "Binary files differ" and `git apply` then refuses. Those blobs are
        # handled by restore_binary_blobs.sh instead, so exclude them here.
        git -C "$TREE/$p" diff > "$out"
        if grep -q "^Binary files " "$out" 2>/dev/null; then
            # Drop the binary entries, keep everything else.
            python3 - "$out" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8', errors='surrogateescape').read()
blocks = re.split(r'(?m)^(?=diff --git )', text)
kept = [b for b in blocks if b.strip() and 'Binary files ' not in b]
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(''.join(kept))
PY
        fi
        # Drop the intent-to-add marks again so the tree looks untouched.
        git -C "$TREE/$p" reset -q >/dev/null 2>&1 || true
        echo "wrote $out ($(wc -l < "$out") lines)"
    done
    exit 0
fi

applied=0
skipped=0
failed=0
missing=0

for p in "${PROJECTS[@]}"; do
    f="$(patch_for "$p")"
    if [ ! -f "$f" ]; then
        continue
    fi
    if [ ! -d "$TREE/$p/.git" ]; then
        echo "?? $p: not a git checkout, cannot apply" >&2
        failed=$((failed + 1))
        continue
    fi

    # Mode-only patches need the explicit mode comparison above; git's own
    # probes are unusable for them.
    mos="$(mode_only_state "$TREE/$p" "$f")"
    if [ -n "$mos" ]; then
        if [ "$mos" = applied ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$MODE" = check ]; then
            echo "-- $p: patch NOT applied (file mode)"
            missing=$((missing + 1))
            continue
        fi
        if git -C "$TREE/$p" apply "$f" >/dev/null 2>&1; then
            echo "++ $p: applied (file mode)"
            applied=$((applied + 1))
        else
            echo "!! $p: could not apply file mode" >&2
            failed=$((failed + 1))
        fi
        continue
    fi

    # Order matters. Probe forward first: if the patch still applies, the
    # working tree is at the pre-image and the patch is missing. Only then ask
    # whether it is already applied.
    #
    # The reverse probe cannot come first: `git apply -R --check` is lenient
    # about pure file-mode changes (it warns "类型是 100644，应为 100755" and
    # exits 0), so a mode-only patch such as prebuilts/r8's d8 +x would be
    # reported as already applied even on a clean checkout, and the chmod would
    # never be replayed.
    if git -C "$TREE/$p" apply --check "$f" >/dev/null 2>&1; then
        if [ "$MODE" = check ]; then
            echo "-- $p: patch NOT applied"
            missing=$((missing + 1))
            continue
        fi
        git -C "$TREE/$p" apply "$f"
        echo "++ $p: applied"
        applied=$((applied + 1))
        continue
    fi

    if git -C "$TREE/$p" apply --reverse --check "$f" >/dev/null 2>&1; then
        skipped=$((skipped + 1))
        continue
    fi

    # Neither direction applies cleanly. Either upstream moved under us, or the
    # working tree carries local edits on top of the patch. Both need a human.
    echo "!! $p: patch neither applies nor is fully applied (upstream moved?)" >&2
    echo "   inspect: git -C $TREE/$p apply --check -v $f" >&2
    failed=$((failed + 1))
done

echo
echo "applied=$applied already-applied=$skipped failed=$failed"
[ "$MODE" = check ] && echo "missing=$missing"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
if [ "$MODE" = check ] && [ "$missing" -ne 0 ]; then
    exit 1
fi
exit 0

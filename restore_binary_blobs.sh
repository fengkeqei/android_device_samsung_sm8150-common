#!/bin/bash
# Restore binary blobs that patches/ cannot carry.
#
# `repo sync` resets every project to its upstream commit. Text changes are
# replayed by apply_patches.sh, but a binary that a project's build files
# reference cannot live in a .patch file. Those blobs are kept in the device
# tree (which is under git) and copied back here.
#
# Run this after apply_patches.sh and before building.
#
#   ./restore_binary_blobs.sh [--check]
#
# --check only reports what is missing; exit 1 if anything is.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-apply}"

missing=0
restored=0
ok=0

# <destination relative to $TREE> <source relative to $TREE>
PAIRS=(
    # hardware/ril/rild/Android.bp ships Samsung's rild as a prebuilt
    # (cc_prebuilt_binary srcs: ["rild_stock"]). Without it PRODUCT_PACKAGES
    # `rild` fails and the device has no radio at all.
    "hardware/ril/rild/rild_stock:device/samsung/sm8150-common/vendor_radio/bin/hw/rild"
)

say() { printf '%s\n' "$*"; }

for pair in "${PAIRS[@]}"; do
    dst="${pair%%:*}"
    src="${pair#*:}"
    dst_path="$TREE/$dst"
    src_path="$TREE/$src"

    if [ ! -f "$src_path" ]; then
        say "!! missing source: $src"
        missing=$((missing + 1))
        continue
    fi

    if [ -f "$dst_path" ] && cmp -s "$src_path" "$dst_path"; then
        ok=$((ok + 1))
        continue
    fi

    if [ "$MODE" = "--check" ]; then
        say "-- $dst: missing or differs"
        missing=$((missing + 1))
        continue
    fi

    mkdir -p "$(dirname "$dst_path")" || { missing=$((missing + 1)); continue; }
    if cp -f "$src_path" "$dst_path"; then
        chmod 755 "$dst_path"
        say "++ $dst: restored"
        restored=$((restored + 1))
    else
        say "!! $dst: copy failed"
        missing=$((missing + 1))
    fi
done

if [ "$MODE" = "--check" ]; then
    say "blobs: ok=$ok missing=$missing"
    [ "$missing" -eq 0 ] || exit 1
else
    say "blobs: ok=$ok restored=$restored failed=$missing"
    [ "$missing" -eq 0 ] || exit 1
fi

#!/system/bin/sh
# Create keymaster64.* aliases of skeymast.* in the APNHLOS firmware image.
# Required by the Samsung MDFPP fingerprint/keymaster key chain; see
# WORKLOG Round 71h (A15) and BUILD_NOTES (A16).
#
# The partition is vfat mounted with fmask=0337,dmask=0227, so `cp` creates the
# destination with a mode the following open() cannot write to, and it fails.
# `cat > dst` opens the already-created empty file for writing and works.
# Never silence these: a silent failure here means the TEE key chain never
# resolves keymaster64, the HAL loops on error 11702, and enrollment dies with
# "BAuth_Hat_OP fail rv : 28".
IMG=/vendor/firmware_mnt/image
[ -f "$IMG/skeymast.mdt" ] || exit 0
for f in "$IMG"/skeymast.*; do
    n="$IMG/keymaster64.${f##*.}"
    [ -e "$n" ] && continue
    : > "$n" || continue
    cat "$f" > "$n" || rm -f "$n"
done
exit 0

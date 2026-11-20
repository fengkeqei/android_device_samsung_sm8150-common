#!/system/bin/sh
# Fix VK (VaultKeeper) key data ownership.
#
# /keydata/misc and /keyrefuge/misc hold the VK ID blobs, but the hashed
# subdirectories come up as root:root 0700 while vaultkeeperd runs as `system`,
# so it cannot read them:
#   vaultkeeper: There is no VK ID
#   vaultkeeper: VaultKeeper service preparation is failed
# The missing VK ID then breaks gatekeeper enroll on the TEE path
# ("Failed to enroll LSKF for new SP protector for user 0"), which in turn
# leaves the fingerprint HAL unable to obtain a TEE-accepted HAT
# (BAuth_Hat_OP rv 28).
for d in /keydata/misc /keyrefuge/misc; do
    [ -d "$d" ] || continue
    chown -R system:system "$d"
    chmod -R 700 "$d"
done
exit 0

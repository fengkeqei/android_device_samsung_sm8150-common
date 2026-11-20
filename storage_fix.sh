#!/system/bin/sh
# v132fix: emulated storage bring-up (idempotent, safe to run repeatedly).
#
# Root cause: vold's onUserStarted only *creates* emulated;0, it never mounts
# it; MediaProvider's FuseDaemon polls and gives up, so the volume stays
# UNMOUNTED -> Files shows no internal root, MediaStore reports
# "Volume external_primary not found", gallery is empty and the camera cannot
# save photos.
#
# Verified final sequence (on device, all three conditions hold at once):
#   1. mount emulated;0 and let StorageManagerService settle (volume STABLE)
#   2. force-stop MediaProvider -> it restarts and its VolumeCache registers
#      external_primary (MediaStore "Row:" appears)
#   3. unmount + mount -> revives the FUSE channel (the old FuseDaemon died
#      with the force-stopped process, leaving "Transport endpoint is not
#      connected" otherwise)
#
# The force-stop must happen only after the volume is STABLE. If it fires too
# early (volume still transitioning), MediaProvider's restart is delayed and
# the volume never registers, so we verify with `content query` and retry.

LOG=/data/vendor/storage_fix.log
exec >>"$LOG" 2>&1
echo "=== storage_fix $(date) ==="

# Wait for MediaProvider's FIRST init to finish before we touch anything:
# force-stopping it mid-init leaves its VolumeCache broken.
sleep 30

for i in 1 2 3 4 5 6 7 8; do
    sm mount "emulated;0" 2>/dev/null
    if sm list-volumes 2>/dev/null | grep -q "emulated;0 mounted"; then
        echo "mounted (attempt $i)"
        break
    fi
    sleep 2
done

# CRITICAL: let StorageManagerService settle after the mount.
sleep 15

# force-stop -> restart -> verify external_primary registered. Retry because
# a too-early force-stop delays MediaProvider's restart past our wait.
for attempt in 1 2 3 4; do
    echo "force-stop attempt $attempt"
    am force-stop com.android.providers.media.module 2>/dev/null
    sleep 20
    if content query --uri content://media/external_primary/file \
            --projection _id 2>/dev/null | grep -qE "^Row"; then
        echo "external_primary registered (attempt $attempt)"
        break
    fi
    echo "not registered yet (attempt $attempt)"
    sleep 10
done

# Revive the FUSE channel after the force-stop killed the old FuseDaemon.
# The final mount is retried: right after the force-stop restart, vold can
# reject the mount transiently and a failed mount leaves the volume unmounted.
sm unmount "emulated;0" 2>/dev/null
sleep 3
for i in 1 2 3 4 5; do
    sm mount "emulated;0" 2>/dev/null
    if sm list-volumes 2>/dev/null | grep -q "emulated;0 mounted"; then
        echo "final mounted (attempt $i)"
        break
    fi
    sleep 2
done
echo "done"

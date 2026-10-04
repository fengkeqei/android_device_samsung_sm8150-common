#!/usr/bin/env bash
#
# Add the firmware mount point directories to a built vendor image.
#
# The stock fstab mounts the apnhlos/modem/dsp partitions at
# /vendor/firmware_mnt, /vendor/firmware-modem and /vendor/dsp. The vendor
# partition is mounted read-only, so those directories have to exist inside the
# image, but soong's fsgen rejects them as PRODUCT_COPY_FILES destinations
# ("Path is outside directory"), so they are added here instead.
#
# Usage: fix_vendor_mountpoints.sh [vendor.img]
#
set -euo pipefail

IMG=${1:-out/target/product/beyond1q/vendor.img}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# SELinux labels must be written NUL-terminated (as in the stock image),
# otherwise the kernel sees a broken label and access is denied.
set_selinux_label() {  # $1 = path inside the image, $2 = label
    printf '%s\0' "$2" > "$TMP/lbl.bin"
    debugfs -w -R "ea_set -f $TMP/lbl.bin $1 security.selinux" "$TMP/vendor.raw" >/dev/null 2>&1 || true
}


[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

simg2img "$IMG" "$TMP/vendor.raw"

for dir in firmware_mnt firmware-modem dsp; do
    debugfs -w -R "mkdir /$dir" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /$dir mode 040755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /$dir uid 0" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /$dir gid 0" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/$dir" "u:object_r:vendor_file:s0"
    echo "added /$dir"
done

# Libraries that vendor HALs need but that are not installed into the vendor
# image (they were pruned from the blob list as "platform libs"). Without them
# the strongbox keymaster and qseecom HALs cannot even load.
STAGE=out/target/product/beyond1q/system
for lib in android.hardware.keymaster@4.1.so libhidlmemory.so \
           android.hidl.memory@1.0.so android.hidl.memory.token@1.0.so; do
    [ -f "$STAGE/lib64/$lib" ] || continue
    debugfs -w -R "rm /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $STAGE/lib64/$lib /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib64/$lib mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib64/$lib" "u:object_r:same_process_hal_file:s0"
    echo "added /lib64/$lib"
done
for lib in libhidlmemory.so android.hidl.memory@1.0.so android.hidl.memory.token@1.0.so; do
    [ -f "$STAGE/lib/$lib" ] || continue
    debugfs -w -R "rm /lib/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $STAGE/lib/$lib /lib/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib/$lib mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib/$lib" "u:object_r:same_process_hal_file:s0"
    echo "added /lib/$lib"
done

# Restore the vendor ueventd.rc (device node permissions; without it
# /dev/kgsl-3d0 stays 0600 root:root and surfaceflinger cannot init EGL).
UEV=device/samsung/sm8150-common/ueventd.rc
if [ -f "$UEV" ]; then
    debugfs -w -R "rm /ueventd.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $UEV /ueventd.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /ueventd.rc mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/ueventd.rc" "u:object_r:vendor_file:s0"
    echo "added /ueventd.rc"
fi

# Copy every stock vendor library that the HALs need but the image lacks
# (HIDL interface libs, gralloc deps, etc.). Sourced from the stock firmware.
VLIBDIR=device/samsung/sm8150-common/vendor_libs
# Libraries whose AOSP source-built variants are already installed into the
# vendor image by the build (composer service + resources, hwc2on adapters,
# and the bluetooth audio session stack). Injecting the stock versions here
# would mismatch the AOSP-built service and break dynamic linking
# ("cannot locate symbol").
#
# bluetooth audio (Round 69): the stock libbluetooth_audio_session.so lacks
# android::bluetooth::audio::BluetoothAudioSession_2_1::
# invalidOffloadAudioConfiguration(), which the AOSP-built
# audio.a2dp.default.so needs. Overwriting it made AudioFlinger fail to load
# the a2dp module ("loadHwModule() error -19") -> no A2DP output device ->
# no bluetooth media audio at all (only SCO for calls).
SKIP_AOSP_BUILT='android.hardware.graphics.composer@2.1.so
android.hardware.graphics.composer@2.1-resources.so
android.hardware.graphics.composer@2.2-resources.so
libhwc2on1adapter.so
libhwc2onfbadapter.so
libbluetooth_audio_session.so
android.hardware.bluetooth.audio@2.0.so'
# Round 71 review of the remaining stock-over-build overrides (all KEPT):
# every item below is linked by stock blobs that need the stock ABI, and the
# image is proven booting+working with these stock copies in place:
#   libhidltransport.so / libhwbinder.so  <- hwcomposer.msmnile, sensors.ssc,
#       samsung wifi@2.0-service, hdcp, OmxVpp, hbtp (AOSP builds are stubs)
#   vendor.display.config@1.{1,2,3}.so    <- hwcomposer + the 1.4..1.11 chain
#       must stay one consistent stock set
#   libprotobuf-cpp-full-3.9.1.so         <- libsec-ril, camera.qcom, NN qti
#   android.hardware.audio.common@5.0.so  <- qti/AOSP BT audio impls (frozen HIDL)
#   android.hardware.bluetooth@1.0.so     <- bluetooth@1.1.so, bt-hidlclient
#       (frozen HIDL, AOSP 1.1-service links it fine)
#   libnl.so                              <- wifi@1.0-service + libwifi-hal
#       (wifi verified working with the stock copy)
#   android.hardware.sensors@2.0-ScopedWakelock.so (/lib) <- 32-bit stock
#       sensors.ssc/grip/bio impls
for d in lib64 lib; do
    for src in "$VLIBDIR/$d"/*.so; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        case "$name" in $SKIP_AOSP_BUILT) echo "skip stock $name (AOSP-built)"; continue;; esac
        debugfs -w -R "rm /$d/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $src /$d/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /$d/$name mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/$d/$name" "u:object_r:same_process_hal_file:s0"
    done
done
echo "copied vendor libs from $VLIBDIR"

# GPU/other firmware for /vendor/firmware (kgsl fails to load a630_sqe.fw
# without it: "loading /vendor/firmware_mnt/image/a630_sqe.fw failed with error -13")
VFW=device/samsung/sm8150-common/vendor_firmware/firmware
if [ -d "$VFW" ]; then
    n=0
    debugfs -w -R "mkdir /firmware" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /firmware mode 040755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /firmware gid 2000" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/firmware" "u:object_r:vendor_firmware_file:s0"
    while IFS= read -r src; do
        rel=${src#"$VFW"/}
        dir=$(dirname "$rel")
        if [ "$dir" != "." ]; then
            debugfs -w -R "mkdir /firmware/$dir" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        fi
        debugfs -w -R "rm /firmware/$rel" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $src /firmware/$rel" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /firmware/$rel mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/firmware/$rel" "u:object_r:vendor_firmware_file:s0"
        n=$((n+1))
    done < <(find "$VFW" -type f)
    echo "copied $n firmware files to /firmware"
fi

# HAL services / init rcs / vintf fragments pruned from the blob list.
# The composer and display-allocator services are required by surfaceflinger
# ("failed to get hwcomposer service"), their HAL declarations were pruned too.
VHAL=device/samsung/sm8150-common/vendor_bins
if [ -d "$VHAL/bin/hw" ]; then
    for src in "$VHAL"/bin/hw/*; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        case "$name" in
            vendor.qti.hardware.display.allocator-service)        lbl="u:object_r:hal_graphics_allocator_default_exec:s0" ;;
            *) continue ;;
        esac
        debugfs -w -R "rm /bin/hw/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $src /bin/hw/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /bin/hw/$name mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/bin/hw/$name" "$lbl"
        echo "added /bin/hw/$name"
    done
    for src in "$VHAL"/etc/init/*.rc; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        case "$name" in
            vendor.qti.hardware.display.allocator-service.rc) ;;
            *) continue ;;
        esac
        debugfs -w -R "rm /etc/init/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $src /etc/init/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /etc/init/$name mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/etc/init/$name" "u:object_r:vendor_configs_file:s0"
    done
    # our own rc additions (early logcat + stdio_to_kmsg composer debug helpers)
    if [ -f device/samsung/sm8150-common/debug_logcat.rc ]; then
        debugfs -w -R "rm /etc/init/debug_logcat.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write device/samsung/sm8150-common/debug_logcat.rc /etc/init/debug_logcat.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /etc/init/debug_logcat.rc mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/etc/init/debug_logcat.rc" "u:object_r:vendor_configs_file:s0"
        echo "updated /etc/init/debug_logcat.rc"
    fi
    if [ -f device/samsung/sm8150-common/capture_composer.sh ]; then
        debugfs -w -R "rm /bin/capture_composer.sh" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write device/samsung/sm8150-common/capture_composer.sh /bin/capture_composer.sh" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /bin/capture_composer.sh mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/bin/capture_composer.sh" "u:object_r:vendor_file:s0"
        echo "added /bin/capture_composer.sh"
    fi
fi
VFRAG=device/samsung/sm8150-common/vendor_fragments
if [ -d "$VFRAG" ]; then
    for src in "$VFRAG"/*.xml; do
        [ -f "$src" ] || continue
        name=$(basename "$src")
        [ "$name" = "power-samsung.xml" ] && continue   # we use the QTI power HAL
        debugfs -w -R "rm /etc/vintf/manifest/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $src /etc/vintf/manifest/$name" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /etc/vintf/manifest/$name mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/etc/vintf/manifest/$name" "u:object_r:vendor_configs_file:s0"
    done
    echo "restored vintf fragments"
fi

# Remove the stock QTI composer 2.4 service: it links against a stock
# libprocessgroup symbol set we do not ship, exits immediately, and its rc
# keeps dragging surfaceflinger down via "onrestart restart surfaceflinger".
for stale in /bin/hw/android.hardware.graphics.composer@2.4-service \
             /etc/init/android.hardware.graphics.composer@2.4-service.rc; do
    debugfs -w -R "rm $stale" "$TMP/vendor.raw" >/dev/null 2>&1 || true
done
echo "removed stock composer@2.4-service"

# Composer stack: use the AOSP source-built variants so they match the
# AOSP-built composer@2.1-service binary (stock -resources.so does not export
# ComposerResources::hasDisplayEnabled and the link fails). These install into
# the vendor partition, so prefer the vendor staging tree; fall back to system
# for libs that only exist there.
VSTAGE=out/target/product/beyond1q/vendor
for lib in android.hardware.graphics.composer@2.1.so \
           android.hardware.graphics.composer@2.1-resources.so \
           libhwc2on1adapter.so \
           libhwc2onfbadapter.so; do
    src=""
    [ -f "$VSTAGE/lib64/$lib" ] && src="$VSTAGE/lib64/$lib"
    [ -n "$src" ] || { echo "MISSING AOSP-built $lib"; continue; }
    debugfs -w -R "rm /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $src /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib64/$lib mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib64/$lib" "u:object_r:same_process_hal_file:s0"
    echo "installed AOSP-built /lib64/$lib"
done

# AOSP-built libbluetooth_audio_session.so (Round 69).
# The stock blob at this path lacks
# android::bluetooth::audio::BluetoothAudioSession_2_1::
# invalidOffloadAudioConfiguration(), which the AOSP-built
# audio.a2dp.default.so references. A previous run of this script injected the
# stock copy from vendor_libs, so the image ended up with the stock version and
# AudioFlinger failed to load the a2dp module ("loadHwModule() error -19"),
# leaving bluetooth media audio dead (only SCO for calls). Force the AOSP
# build output here (it is what the AOSP a2dp HAL was linked against).
for arch in lib lib64; do
    src="out/target/product/beyond1q/vendor/$arch/libbluetooth_audio_session.so"
    if [ ! -f "$src" ]; then echo "MISSING AOSP-built $arch/libbluetooth_audio_session.so"; continue; fi
    debugfs -w -R "rm /$arch/libbluetooth_audio_session.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $src /$arch/libbluetooth_audio_session.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /$arch/libbluetooth_audio_session.so mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/$arch/libbluetooth_audio_session.so" "u:object_r:same_process_hal_file:s0"
    echo "installed AOSP-built /$arch/libbluetooth_audio_session.so"
done

# HIDL interface libs that only the system image carries (vendor HALs need them
# at runtime, and the stock vendor partition does not ship them).
for lib in android.hardware.graphics.composer@2.2.so \
           android.hardware.graphics.composer@2.3.so \
           android.hardware.graphics.composer@2.4.so \
           android.hardware.graphics.composer@2.2-resources.so \
           libsync.so libprocessgroup.so \
           android.system.net.netd@1.1.so; do
    [ -f "$STAGE/lib64/$lib" ] || continue
    debugfs -w -R "rm /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $STAGE/lib64/$lib /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib64/$lib mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib64/$lib" "u:object_r:same_process_hal_file:s0"
done

# Samsung MDFPP TEE gatekeeper (replaces the AOSP software stub)
#
# The AOSP software gatekeeper never mints a hw_auth_token_t, so gatekeeperd never
# registers one with keystore and the SID-bound Synthetic-Password protector key can
# never be used -> "No suitable auth token" -> the lock screen can never be unlocked.
# Samsung's stock module talks to the TEE gatekeeper TA over /dev/qseecom and mints
# real HATs. It needs an OpenSSL 1.1 libcrypto, so it is redirected to a private
# "libcrypto_gk" (DT_NEEDED/SONAME renamed in place, and the module's DT_NEEDED too).
# See device/samsung/sm8150-common/vendor_gatekeeper/README.md.
VGK=device/samsung/sm8150-common/vendor_gatekeeper
if [ -f "$VGK/gatekeeper.default.so" ]; then
    debugfs -w -R "rm /lib64/hw/gatekeeper.default.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $VGK/gatekeeper.default.so /lib64/hw/gatekeeper.default.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib64/hw/gatekeeper.default.so mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib64/hw/gatekeeper.default.so" "u:object_r:vendor_file:s0"
    echo "installed MDFPP gatekeeper module -> /lib64/hw/gatekeeper.default.so"
fi
if [ -f "$VGK/libcrypto_gk" ]; then
    debugfs -w -R "rm /lib64/libcrypto_gk" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $VGK/libcrypto_gk /lib64/libcrypto_gk" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib64/libcrypto_gk mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib64/libcrypto_gk" "u:object_r:vendor_file:s0"
    echo "installed MDFPP private libcrypto -> /lib64/libcrypto_gk"
fi
if [ -f "$VGK/android.hardware.gatekeeper@1.0-service.rc" ]; then
    debugfs -w -R "rm /etc/init/android.hardware.gatekeeper@1.0-service.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $VGK/android.hardware.gatekeeper@1.0-service.rc /etc/init/android.hardware.gatekeeper@1.0-service.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /etc/init/android.hardware.gatekeeper@1.0-service.rc mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/etc/init/android.hardware.gatekeeper@1.0-service.rc" "u:object_r:vendor_configs_file:s0"
    echo "installed gatekeeper rc (drmrpc group) -> /etc/init/android.hardware.gatekeeper@1.0-service.rc"
fi
# HIDL passthrough bridge: the gatekeeper service dlopens this before it ever
# touches gatekeeper.default.so. If it is missing the service exits 1 within
# ~5 ms ("Could not get passthrough implementation"), hwservicemanager restarts
# it every second, and after 4 crashes RescueParty blocks boot entirely
# (stuck on the boot animation). Injected here as a safety net even though
# android.hardware.gatekeeper@1.0-impl is in PRODUCT_PACKAGES.
if [ -f "$VGK/android.hardware.gatekeeper@1.0-impl.so" ]; then
    debugfs -w -R "rm /lib64/hw/android.hardware.gatekeeper@1.0-impl.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $VGK/android.hardware.gatekeeper@1.0-impl.so /lib64/hw/android.hardware.gatekeeper@1.0-impl.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib64/hw/android.hardware.gatekeeper@1.0-impl.so mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib64/hw/android.hardware.gatekeeper@1.0-impl.so" "u:object_r:vendor_file:s0"
    echo "installed gatekeeper passthrough impl -> /lib64/hw/android.hardware.gatekeeper@1.0-impl.so"
fi

# Samsung stock rild + patched libsec-ril (Round 44/45/69)
#
# The device tree intentionally ships the AOSP-source rild (Round 43), but the
# AOSP libril registers IRadio only up to 1.1. Android 15's telephony wants
# IRadio up to 1.4 (plus the AIDL radio HALs); with the source rild
# com.android.phone ANR-loops at startup ("failed to complete startup") and the
# modem stays dead (no IMEI/service). Samsung's stock rild registers 1.0-1.4
# through libril_sem.so; it reads vendor.sec.rild.libpath (set in
# beyond1q/beyond1q_product_bind.rc) and needs a patched libsec-ril.so
# (DT_NEEDED/SONAME fix). Both were runtime-only hot fixes until Round 69, so a
# vendor rebuild silently lost the modem -- this section makes it permanent.
VRADIO=device/samsung/sm8150-common/vendor_radio
if [ -f "$VRADIO/bin/hw/rild" ]; then
    debugfs -w -R "rm /bin/hw/rild" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $VRADIO/bin/hw/rild /bin/hw/rild" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /bin/hw/rild mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /bin/hw/rild uid 0" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /bin/hw/rild gid 2000" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/bin/hw/rild" "u:object_r:rild_exec:s0"
    echo "installed stock rild -> /bin/hw/rild"
fi
if [ -f "$VRADIO/lib64/libsec-ril.so" ]; then
    debugfs -w -R "rm /lib64/libsec-ril.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $VRADIO/lib64/libsec-ril.so /lib64/libsec-ril.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif /lib64/libsec-ril.so mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "/lib64/libsec-ril.so" "u:object_r:vendor_file:s0"
    echo "installed patched libsec-ril -> /lib64/libsec-ril.so"
fi

# Device VINTF manifest must be the stock *shell*, never the LOS-merged
# manifest the build installs from device/.../manifest.xml. los_backfill.xml
# declares the very same HALs (audio@6.0 IDevicesFactory, ...), and libvintf
# rejects the ENTIRE device manifest on the first duplicate
# ("NULL VINTF MANIFEST") -> every AIDL HAL (health, light, ...) is denied at
# registration (EX_ILLEGAL_ARGUMENT "VINTF declaration error") ->
# SystemServer BatteryService FATAL -> bootloop (Round 67; same class of bug
# as Round 51). The shell + backfill + fragments combo is the proven-good
# combination (boots clean).
VDTC=device/samsung/sm8150-common
for pair in "manifest_stock_shell.xml:/etc/vintf/manifest.xml" \
            "los_backfill.xml:/etc/vintf/manifest/los_backfill.xml"; do
    src=${pair%%:*}; dst=${pair#*:}
    if [ ! -f "$VDTC/$src" ]; then
        echo "MISSING $VDTC/$src"
        continue
    fi
    debugfs -w -R "rm $dst" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $VDTC/$src $dst" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif $dst mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "$dst" "u:object_r:vendor_configs_file:s0"
    echo "installed $dst (from $src)"
done

img2simg "$TMP/vendor.raw" "$IMG"
echo "rewrote $IMG"

#!/usr/bin/env bash
#
# Inject the HIDL interface libraries that A16 no longer lets vendor processes
# resolve from /system/lib64 (VNDK was removed) into the built vendor image.
#
# Why post-processing instead of PRODUCT_PACKAGES: every Samsung vendor HAL is a
# prebuilt blob with DISABLE_DEPS, so nothing in the soong dependency graph ever
# references the vendor_available hidl_interface modules. PRODUCT_PACKAGES then
# installs only their system variant into system/lib64, and the vendor variants
# never reach the vendor image's file list. Same approach as the reference
# tree's fix_vendor_mountpoints.sh.
#
# Usage: inject_vendor_hidl_libs.sh [vendor.img]
#
set -euo pipefail

IMG=${1:-out/target/product/beyond1q/vendor.img}
STAGE=out/target/product/beyond1q/vendor
SYSSTAGE=out/target/product/beyond1q/system
STOCK=device/samsung/sm8150-common/vendor_libs
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

set_selinux_label() {
    printf '%s\0' "$2" > "$TMP/lbl.bin"
    debugfs -w -R "ea_set -f $TMP/lbl.bin $1 security.selinux" "$TMP/vendor.raw" >/dev/null 2>&1 || true
}

[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
simg2img "$IMG" "$TMP/vendor.raw"

install_lib() {
    local src=$1 dst=$2
    debugfs -w -R "rm $dst" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $src $dst" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif $dst mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif $dst uid 0" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "sif $dst gid 0" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    set_selinux_label "$dst" "u:object_r:same_process_hal_file:s0"
    echo "  + $dst"
}

# Resolve a library from the best available source:
#   1. vendor staging (soong-built vendor variant, AOSP ABI)
#   2. system staging  (AOSP core variant; HIDL interface libs are identical)
#   3. stock vendor_libs (no AOSP module in A16)
resolve_and_install() {
    local lib=$1 got=0
    # Vendor HAL services exist in both 32- and 64-bit flavours (widevine and
    # the Samsung camera provider are 32-bit; most others are 64-bit), so install
    # every available bitness. 64-bit first, then the 32-bit twin.
    if [ -f "$STAGE/lib64/$lib" ]; then
        install_lib "$STAGE/lib64/$lib" "/lib64/$lib"; got=1
    elif [ -f "$SYSSTAGE/lib64/$lib" ]; then
        install_lib "$SYSSTAGE/lib64/$lib" "/lib64/$lib"; got=1
    elif [ -f "$STOCK/lib64/$lib" ]; then
        install_lib "$STOCK/lib64/$lib" "/lib64/$lib"; got=1
    fi
    if [ -f "$STAGE/lib/$lib" ]; then
        install_lib "$STAGE/lib/$lib" "/lib/$lib"; got=1
    elif [ -f "$SYSSTAGE/lib/$lib" ]; then
        install_lib "$SYSSTAGE/lib/$lib" "/lib/$lib"; got=1
    elif [ -f "$STOCK/lib/$lib" ]; then
        install_lib "$STOCK/lib/$lib" "/lib/$lib"; got=1
    fi
    [ "$got" = 1 ] || echo "  ! UNRESOLVED $lib"
}

# Every library the vendor HAL binaries link. logcat only reports the first
# unresolved DT_NEEDED per binary, so each one hides the next: fixing health@2.1
# exposed health@2.0, and so on. This list is the union over all 19 services
# that failed with "CANNOT LINK EXECUTABLE" plus the libs those then need.
LIBS="
android.hardware.health@2.1.so
android.hardware.health@2.0.so
android.hardware.health@1.0.so
android.hardware.usb@1.0.so
android.hardware.usb@1.1.so
android.hardware.usb@1.2.so
android.hardware.usb@1.3.so
android.hardware.neuralnetworks@1.0.so
android.hardware.neuralnetworks@1.1.so
android.hardware.neuralnetworks@1.2.so
android.hardware.neuralnetworks@1.3.so
android.hardware.drm@1.0.so
android.hardware.drm@1.1.so
android.hardware.drm@1.2.so
android.hardware.drm@1.3.so
android.hardware.gnss@1.0.so
android.hardware.gnss@1.1.so
android.hardware.gnss@2.0.so
android.hardware.gnss@2.1.so
android.hardware.camera.common@1.0.so
android.hardware.camera.device@1.0.so
android.hardware.camera.device@3.2.so
android.hardware.camera.device@3.3.so
android.hardware.camera.device@3.4.so
android.hardware.camera.device@3.5.so
android.hardware.camera.device@3.6.so
android.hardware.camera.provider@2.4.so
android.hardware.camera.provider@2.5.so
android.hardware.camera.provider@2.6.so
android.frameworks.cameraservice.service@2.0.so
android.frameworks.cameraservice.service@2.1.so
android.hardware.thermal@1.0.so
android.hardware.thermal@2.0.so
android.hardware.wifi@1.0.so
android.hardware.wifi@1.1.so
android.hardware.wifi@1.2.so
android.hardware.wifi@1.3.so
android.hardware.wifi@1.4.so
android.hidl.allocator@1.0.so
android.hidl.memory@1.0.so
libhidlmemory.so
libcamera_metadata.so
libprocessgroup.so
libjson.so
libwifi-hal.so
libwifi-system-iface.so
libgps.utils.so
libqti_vndfwk_detect.so
libvndksupport.so
libwvhidl.so
librmnetctl.so
libqti-perfd-client.so
vendor.qti.hardware.perf@2.0.so
vendor.qti.hardware.perf@2.1.so
vendor.qti.hardware.perf@2.2.so
libsync.so
libwvhidl.so
android.hardware.vibrator@1.0.so
android.hardware.vibrator@1.1.so
android.hardware.vibrator@1.2.so
android.hardware.vibrator@1.3.so
android.hardware.drm@1.0.so
android.hardware.drm@1.1.so
android.hardware.drm@1.2.so
android.hardware.drm@1.3.so
android.hardware.camera.common@1.0.so
android.hardware.camera.device@1.0.so
android.hardware.camera.device@3.2.so
android.hardware.camera.device@3.3.so
android.hardware.camera.device@3.4.so
android.hardware.camera.device@3.5.so
android.hardware.camera.device@3.6.so
android.hardware.camera.provider@2.4.so
android.hidl.allocator@1.0.so
libcamera_metadata.so
android.system.net.netd@1.1.so
libandroid_net.so
android.hardware.power-V1-ndk_platform.so
vendor.samsung.hardware.snap@1.2-impl.so
"

echo "injecting vendor HAL interface libraries into $IMG:"
for lib in $LIBS; do
    resolve_and_install "$lib"
done

# HAL implementations that live in vendor/lib*/hw (dlopened by the passthrough
# service manager, not DT_NEEDED on the service binary itself).
echo "injecting hw/ HAL implementation modules:"
for lib in vendor.samsung.hardware.snap@1.2-impl.so; do
    for d in lib64 lib; do
        if [ -f "$STAGE/$d/hw/$lib" ]; then
            debugfs -w -R "rm /$d/hw/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
            debugfs -w -R "write $STAGE/$d/hw/$lib /$d/hw/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
            debugfs -w -R "sif /$d/hw/$lib mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
            set_selinux_label "/$d/hw/$lib" "u:object_r:same_process_hal_file:s0"
            echo "  + /$d/hw/$lib"
        fi
    done
done

# Samsung's health HAL binary is named ...-service-samsung, which the stock AOSP
# file_contexts rule for android.hardware.health@2.1-service does not match, so
# it falls back to vendor_file. init then refuses to exec it ("has incorrect
# label ... expected hal_health_default_exec"), the service exits 4 times and
# android.hardware.health@2.0::IHealth/default is never registered -- which
# blocks BatteryService.onStart on the system_server main thread. The device
# tree's sepolicy/vendor/file_contexts now declares the rule; this sets the
# attribute on the already-built image so no rebuild is needed.
echo "fixing health service exec label:"
HEALTH_SVC=/bin/hw/android.hardware.health@2.1-service-samsung
HEALTH_RULE='/(vendor|vendor_dlkm)/bin/hw/android\.hardware\.health@2\.1-service-samsung u:object_r:hal_health_default_exec:s0'
if debugfs -R "stat $HEALTH_SVC" "$TMP/vendor.raw" 2>/dev/null | grep -q Inode:; then
    set_selinux_label "$HEALTH_SVC" "u:object_r:hal_health_default_exec:s0"
    echo "  ~ $HEALTH_SVC -> hal_health_default_exec"

    # init re-runs restorecon from /vendor/etc/selinux/vendor_file_contexts on
    # every boot, so the attribute alone would be reverted. Append the rule to
    # the image's copy of that file (generated at build time from the device
    # tree's sepolicy; the device-tree rule added to
    # sepolicy/vendor/file_contexts makes this match what a full rebuild emits).
    VFC=/etc/selinux/vendor_file_contexts
    if debugfs -R "dump $VFC $TMP/vfc.txt" "$TMP/vendor.raw" >/dev/null 2>&1 && [ -s "$TMP/vfc.txt" ]; then
        if ! grep -qF "health@2\.1-service-samsung" "$TMP/vfc.txt"; then
            printf '%s\n' "$HEALTH_RULE" >> "$TMP/vfc.txt"
            debugfs -w -R "rm $VFC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
            debugfs -w -R "write $TMP/vfc.txt $VFC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
            debugfs -w -R "sif $VFC mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
            set_selinux_label "$VFC" "u:object_r:vendor_configs_file:s0"
            echo "  + $VFC (health rule appended)"
        else
            echo "  = $VFC already has the rule"
        fi
    else
        echo "  ! could not read $VFC"
    fi
fi

# A16 bring-up: /data must be mounted before class_start main or vold blocks
# forever on android.security.maintenance (keystore2 cannot initialise without
# /data) and boot never completes. init.target.rc imports
# init.samsung.rc + init.${ro.product.vendor.device}.rc, but never
# init.qcom.rc -- so the `on late-fs: mount_all --late` that used to live in
# init.qcom.rc was never executed (last_kmsg 2026-10-30 shows only
# "mount_all ... --early" and /data never mounts). Patch the imported file.
echo "patching init.beyond1q.rc for late-fs mount:"
B1Q=/etc/init/hw/init.beyond1q.rc
if debugfs -R "cat $B1Q" "$TMP/vendor.raw" 2>/dev/null > "$TMP/b1q.rc" && [ -s "$TMP/b1q.rc" ]; then
    if ! grep -q "mount_all /vendor/etc/fstab.qcom --late" "$TMP/b1q.rc"; then
        cat >> "$TMP/b1q.rc" <<'RCEOF'

# A16 bring-up: /data must be mounted before class_start main, or vold blocks
# forever on android.security.maintenance (keystore2 needs /data). This file is
# imported by init.target.rc; init.qcom.rc is not.
on late-fs
    mount_all /vendor/etc/fstab.qcom --late
RCEOF
        debugfs -w -R "rm $B1Q" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/b1q.rc $B1Q" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif $B1Q mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "$B1Q" "u:object_r:vendor_configs_file:s0"
        echo "  + $B1Q (late-fs mount_all appended)"
    else
        echo "  = $B1Q already patched"
    fi
else
    echo "  ! could not read $B1Q"
fi

# qseecom-service (the HIDL wrapper around the QSEE TEE) exits 1 within ~6 ms
# every 5 s, so vaultkeeperd never gets a working TEE and reports
# "There is no VK ID". Its interface library and the QSEE client API are both
# labelled vendor_file, and a vendor HAL process cannot load vendor_file-typed
# libraries (same reason the 19 HAL services failed to link). Re-label them
# same_process_hal_file, matching libhidlbase and the rest of the HAL stack.
echo "relabelling qseecom HAL libraries:"
for lib in vendor.qti.hardware.qseecom@1.0.so libQSEEComAPI.so libQSEEComAPI_vendor.so; do
    for d in lib64 lib; do
        p="/$d/$lib"
        if debugfs -R "stat $p" "$TMP/vendor.raw" 2>/dev/null | grep -q Inode:; then
            set_selinux_label "$p" "u:object_r:same_process_hal_file:s0"
            echo "  ~ $p"
        fi
    done
done
# The HIDL passthrough implementation lives in lib*/hw and is dlopened by
# PassthroughServiceManager; a vendor_file label there fails the same way.
for d in lib64 lib; do
    p="/$d/hw/vendor.qti.hardware.qseecom@1.0-impl.so"
    if debugfs -R "stat $p" "$TMP/vendor.raw" 2>/dev/null | grep -q Inode:; then
        set_selinux_label "$p" "u:object_r:same_process_hal_file:s0"
        echo "  ~ $p"
    fi
done
# Persist the rule: init re-runs restorecon from vendor_file_contexts on every
# boot, which would put vendor_file back on all of the above.
QSEE_RULE='/(vendor|vendor_dlkm)/lib(64)?/(hw/)?vendor\.qti\.hardware\.qseecom@1\.0(-impl)?\.so u:object_r:same_process_hal_file:s0'
VFC=/etc/selinux/vendor_file_contexts
if debugfs -R "dump $VFC $TMP/vfc_qsee.txt" "$TMP/vendor.raw" >/dev/null 2>&1 && [ -s "$TMP/vfc_qsee.txt" ]; then
    if ! grep -qF "qseecom@1.0" "$TMP/vfc_qsee.txt"; then
        printf '%s\n' "$QSEE_RULE" >> "$TMP/vfc_qsee.txt"
        debugfs -w -R "rm $VFC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/vfc_qsee.txt $VFC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif $VFC mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "$VFC" "u:object_r:vendor_configs_file:s0"
        echo "  + $VFC (qseecom rule appended)"
    fi
fi

# keydata/keyrefuge hold the vaultkeeper VK ID. Their fstab lines carried
# `check`, and e2fsck refuses to skip ("3044 days without being checked") --
# combined with `errors=panic` the mount fails, and `nofail` then swallows it
# silently. Without /keydata mounted, vaultkeeperd reports "There is no VK ID",
# its service preparation fails, vold blocks forever on
# android.security.maintenance, and boot never completes (last_kmsg 2026-10-30).
# Drop `check` (and the panic-on-error policy) so the partitions simply mount.
echo "patching fstab.qcom for keydata/keyrefuge:"
FSTAB=/etc/fstab.qcom
if debugfs -R "cat $FSTAB" "$TMP/vendor.raw" 2>/dev/null > "$TMP/fstab" && [ -s "$TMP/fstab" ]; then
    changed=0
    for part in keydata keyrefuge; do
        if grep -q "by-name/$part" "$TMP/fstab"; then
            # Drop the flags on the line(s) whose second field is the mount point
            # for this partition (sed range by address is fragile here).
            awk -v part="$part" '
                $1 ~ ("by-name/" part) {
                    gsub(/,check/, ""); gsub(/,errors=panic/, "");
                    gsub(/errors=panic,/, "");
                    found=1
                }
                { print }
                END { exit found ? 0 : 1 }
            ' "$TMP/fstab" > "$TMP/fstab.new" && mv "$TMP/fstab.new" "$TMP/fstab" && changed=1
        fi
    done
    if [ "$changed" = 1 ]; then
        debugfs -w -R "rm $FSTAB" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/fstab $FSTAB" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif $FSTAB mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "$FSTAB" "u:object_r:vendor_configs_file:s0"
        echo "  + $FSTAB (keydata/keyrefuge: dropped check + errors=panic)"
    else
        echo "  = $FSTAB already patched"
    fi
else
    echo "  ! could not read $FSTAB"
fi

img2simg "$TMP/vendor.raw" "$IMG"
echo "rewrote $IMG"

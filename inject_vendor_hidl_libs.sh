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
PROP=vendor/samsung/sm8150-common/proprietary/vendor
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

set_selinux_label() {
    # Trailing extra NUL: debugfs 1.47 ea_set -f drops the last byte of values
    # >= 51 bytes (v36 round: the 51-byte hal_graphics_allocator_default_exec
    # context silently became "...:s"). The kernel stops at the first NUL, so
    # the padding is harmless for short values and protects long ones.
    printf '%s\0\0' "$2" > "$TMP/lbl.bin"
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
    elif [ -f "$PROP/lib64/$lib" ]; then
        install_lib "$PROP/lib64/$lib" "/lib64/$lib"; got=1
    elif [ -f "$STOCK/lib64/$lib" ]; then
        install_lib "$STOCK/lib64/$lib" "/lib64/$lib"; got=1
    fi
    if [ -f "$STAGE/lib/$lib" ]; then
        install_lib "$STAGE/lib/$lib" "/lib/$lib"; got=1
    elif [ -f "$SYSSTAGE/lib/$lib" ]; then
        install_lib "$SYSSTAGE/lib/$lib" "/lib/$lib"; got=1
    elif [ -f "$PROP/lib/$lib" ]; then
        install_lib "$PROP/lib/$lib" "/lib/$lib"; got=1
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
android.hidl.memory.token@1.0.so
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
android.hardware.bluetooth@1.0.so
libcodec2_hidl@1.0.so
libcodec2_soft_common.so
libcodec2.so
libcodec2_vndk.so
libsfplugin_ccodec_utils.so
android.hardware.graphics.bufferqueue@1.0.so
android.hardware.graphics.bufferqueue@2.0.so
android.hardware.media@1.0.so
android.hardware.media.bufferpool@2.0.so
android.hardware.media.c2@1.0.so
android.hardware.media.omx@1.0.so
libstagefright_bufferpool@2.0.1.so
libstagefright_bufferqueue_helper.so
android.frameworks.sensorservice@1.0.so
android.hardware.sensors@1.0.so
libdrm.so
libgralloc.qti.so
liblocation_api.so
libloc_core.so
libOmxCore.so
libOpenCL.so
libqdMetaData.so
libqdutils.so
libsensorndkbridge.so
libstagefright_flacdec.so
libsynaFpSensorTestNwd.so
libtinyxml.so
libxml.so
vendor.qti.hardware.bluetooth_audio@2.0.so
vendor.qti.hardware.display.mapper@4.0.so
vendor.qti.hardware.display.mapperextensions@1.0.so
vendor.qti.hardware.display.mapperextensions@1.1.so
# Round-78: eglSubDriverAndroid.so (Samsung EGL sub-driver) dep — was missing
vendor.qti.hardware.display.mapper@2.0.so
libplatformconfig.so
libdisplayconfig.qti.so
libqservice.so
libdisplaydebug.so
libsdmutils.so
# Round-73: display core stack (hwc/gralloc deps missed by the earlier audit
# because it scanned /lib64 only, not the /lib64/hw module's DT_NEEDED)
libsdmcore.so
libgrallocutils.so
libgralloccore.so
libgpu_tonemapper.so
# Round-73: remaining boot-relevant gaps seen in boot logs
libavservices_minijail.so
libjsoncpp.so
android.hardware.gnss.measurement_corrections@1.0.so
android.system.keystore2-V1-ndk.so
android.hardware.radio@1.5.so
android.hardware.radio@1.6.so
android.hardware.camera.provider@2.5.so
android.hardware.camera.provider@2.6.so
android.frameworks.sensorservice@1.0.so
# Round-74: hwcomposer.msmnile.so (A16 qcom display HAL) full dependency set
android.hardware.graphics.composer@2.2.so
android.hardware.graphics.composer@2.3.so
android.hardware.graphics.composer@2.4.so
vendor.display.config@1.4.so
vendor.display.config@1.5.so
vendor.display.config@1.6.so
vendor.display.config@1.7.so
vendor.display.config@1.8.so
vendor.display.config@1.9.so
vendor.display.config@1.10.so
vendor.display.config@1.11.so
# Round-77: libsdedrm.so — the actual DRMManager implementation that
# libdrmutils dlopen()s. Without it HWInfoDRM::Init leaves drm_mgr_intf_
# null and every composer (2.1 and 2.4) SIGSEGVs in GetSystemInfo.
libsdedrm.so
android.hardware.memtrack@1.0.so
# Round-79: memtrack HAL (system_server startMemtrackProxyService blocks on it)
android.hardware.memtrack@1.0-impl.so
memtrack.msmnile.so
# Round-75: libsdmcore's deps (recursive closure of the display stack)
libdrmutils.so
libdisplaycolor.so
libsdmextension.so
# Round-76: Samsung 2.4 composer (the stock hwcomposer service)
libhwc2on1adapter.so
libhwc2onfbadapter.so
android.hardware.graphics.composer@2.1-resources.so
android.hardware.graphics.composer@2.2-resources.so
android.hardware.radio.deprecated@1.0.so
android.hardware.radio@1.4.so
vendor.samsung.hardware.radio@2.2.so
android.hardware.sensors@2.0-ScopedWakelock.so
libstagefright_softomx.so
vendor.nxp.nxpnfc@1.0.so
android.hardware.automotive.vehicle@2.0.so
android.hardware.radio@1.2.so
android.hardware.radio@1.3.so
vendor.display.config@2.0.so
android.hardware.radio.config@1.0.so
android.hardware.radio.config@1.1.so
android.hardware.radio.config@1.2.so
vendor.samsung.hardware.radio@2.0.so
vendor.samsung.hardware.radio@2.1.so
vendor.qti.hardware.display.mapper@3.0.so
vendor.qti.hardware.display.mapper@1.1.so
android.hardware.biometrics.fingerprint@2.1.so
camera.device@1.0-impl.so
camera.device@3.2-impl.so
camera.device@3.3-impl.so
camera.device@3.4-impl.so
camera.device@3.5-impl.so
libcld80211.so
libpasn.so
vendor.qti.hardware.camera.device@1.0.so
vendor.qti.hardware.display.mapper@1.0.so
libkeystore-engine-wifi-hidl.so
android.hardware.wifi.hostapd@1.0.so
android.hardware.wifi.hostapd@1.1.so
android.hardware.wifi.hostapd@1.2.so
android.hardware.wifi.supplicant@1.0.so
libsync.so
libwvhidl.so
# Round-80: QTI allocator service deps + restored libs (libdisplayqos/libsync
# were dropped from vendor between the 29th and the injector rewrites;
# libsdmextension.so hard-links libdisplayqos.so)
libdisplayqos.so
libgrallocusage.so
vendor.qti.hardware.display.allocator@4.0.so
vendor.qti.hardware.display.allocator@3.0.so
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

# ---- qseecom (QSEE TEE HIDL wrapper) ----------------------------------------
# qseecom-service exits 1 within ~5 ms and init restarts it every 5 s, so the
# TEE is never available: vaultkeeperd reports "There is no VK ID",
# vendor.keymaster-4-0 exits 255 every 50 s, `vdc keymaster earlyBootEnded`
# never returns, the post-fs-data action blocks on that exec, and
# nonencrypted/class_start main never fire (boot 2026-10-30).
#
# A vendor HAL process cannot load vendor_file-typed libraries, so the interface
# lib, the QSEE client API and the hw/ passthrough impl all need
# same_process_hal_file (same rule that fixed the other 19 HAL services).
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
for d in lib64 lib; do
    p="/$d/hw/vendor.qti.hardware.qseecom@1.0-impl.so"
    if debugfs -R "stat $p" "$TMP/vendor.raw" 2>/dev/null | grep -q Inode:; then
        set_selinux_label "$p" "u:object_r:same_process_hal_file:s0"
        echo "  ~ $p"
    fi
done

# Persist the qseecom rule in vendor_file_contexts, otherwise restorecon puts
# vendor_file back on every boot.
QSEE_RULE='/(vendor|vendor_dlkm)/lib(64)?/(hw/)?vendor\.qti\.hardware\.qseecom@1\.0(-impl)?\.so u:object_r:same_process_hal_file:s0'
VFC_Q=/etc/selinux/vendor_file_contexts
if debugfs -R "dump $VFC_Q $TMP/vfc_q.txt" "$TMP/vendor.raw" >/dev/null 2>&1 && [ -s "$TMP/vfc_q.txt" ]; then
    if ! grep -qF "qseecom@1.0" "$TMP/vfc_q.txt"; then
        printf '%s\n' "$QSEE_RULE" >> "$TMP/vfc_q.txt"
        debugfs -w -R "rm $VFC_Q" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/vfc_q.txt $VFC_Q" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif $VFC_Q mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "$VFC_Q" "u:object_r:vendor_configs_file:s0"
        echo "  + $VFC_Q (qseecom rule appended)"
    fi
fi

# Round-81: composer -resources libs must pair with the Samsung composer
# blobs (HWC2 resource-cache struct layout is not a stable ABI). resolve_
# and_install prefers the soong build, which A16's composer@2.1-resources
# wins — the Samsung composer@2.4-service then aborts with
# "__next_prime overflow" on its first real transaction (v38).
echo "pairing composer -resources libs with the Samsung blobs:"
# Round-81: the whole composer service chain must be Samsung-built — the
# HWC2 adapter and the composer proxy libs carry HWC2 dispatch tables and
# resource-cache layouts that are not stable across soong builds. The A16
# variants made the Samsung composer@2.4-service fail composer-resources
# creation (v38/v39).
for lib in libhwc2on1adapter.so libhwc2onfbadapter.so \
           android.hardware.graphics.composer@2.2.so \
           android.hardware.graphics.composer@2.3.so \
           android.hardware.graphics.composer@2.4.so; do
    for src in "$PROP/lib64/$lib" "$STOCK/lib64/$lib"; do
        if [ -f "$src" ]; then
            debugfs -w -R "rm /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
            debugfs -w -R "write $src /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1
            debugfs -w -R "sif /lib64/$lib mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
            debugfs -w -R "sif /lib64/$lib uid 0" "$TMP/vendor.raw" >/dev/null 2>&1
            debugfs -w -R "sif /lib64/$lib gid 0" "$TMP/vendor.raw" >/dev/null 2>&1
            set_selinux_label "/lib64/$lib" "u:object_r:same_process_hal_file:s0"
            echo "  + /lib64/$lib (Samsung: $src)"
            break
        fi
    done
done
for lib in android.hardware.graphics.composer@2.1-resources.so android.hardware.graphics.composer@2.2-resources.so; do
    if [ -f "$PROP/lib64/$lib" ]; then
        debugfs -w -R "rm /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $PROP/lib64/$lib /lib64/$lib" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif /lib64/$lib mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif /lib64/$lib uid 0" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif /lib64/$lib gid 0" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "/lib64/$lib" "u:object_r:same_process_hal_file:s0"
        echo "  + /lib64/$lib (Samsung blob)"
    fi
done

# ---- Round-80: QTI allocator service (the mapper@4.0 provider) --------------
# SF's eglInitialize (via eglSubDriverAndroid.so) waits forever on
# android.hardware.graphics.mapper@4.0::IMapper/default. That instance is
# served by this R-style allocator service; without the binary every GPU
# client deadlocks and system_server ANRs on waitForService<ISurfaceComposer>.
# The service binary is registered eagerly via `class hal`, so the stock rc's
# missing `interface` lines don't matter. The fragment declares
# allocator@3.0/4.0 + IQtiAllocator@3.0/4.0; the same @4.0::IAllocator/default
# entry must then be REMOVED from the main manifest to avoid a duplicate.
echo "injecting QTI allocator service (mapper@4.0 provider):"
ALLOC_BIN=$PROP/bin/hw/vendor.qti.hardware.display.allocator-service
if [ -f "$ALLOC_BIN" ]; then
    debugfs -w -R "rm /bin/hw/vendor.qti.hardware.display.allocator-service" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $ALLOC_BIN /bin/hw/vendor.qti.hardware.display.allocator-service" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /bin/hw/vendor.qti.hardware.display.allocator-service mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /bin/hw/vendor.qti.hardware.display.allocator-service uid 0" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /bin/hw/vendor.qti.hardware.display.allocator-service gid 0" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/bin/hw/vendor.qti.hardware.display.allocator-service" "u:object_r:hal_graphics_allocator_default_exec:s0"
    echo "  + /bin/hw/vendor.qti.hardware.display.allocator-service"

    awk '/^service vendor\.qti\.hardware\.display\.allocator/ { print; print "    stdio_to_kmsg"; next } { print }' \
        "$PROP/etc/init/vendor.qti.hardware.display.allocator-service.rc" > "$TMP/allocator.rc"
    debugfs -w -R "rm /etc/init/vendor.qti.hardware.display.allocator-service.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $TMP/allocator.rc /etc/init/vendor.qti.hardware.display.allocator-service.rc" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /etc/init/vendor.qti.hardware.display.allocator-service.rc mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/etc/init/vendor.qti.hardware.display.allocator-service.rc" "u:object_r:vendor_configs_file:s0"
    echo "  + /etc/init/vendor.qti.hardware.display.allocator-service.rc (stdio_to_kmsg)"

    debugfs -w -R "rm /etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $PROP/etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml /etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml" "u:object_r:vendor_configs_file:s0"
    echo "  + /etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml"

    if debugfs -R "cat /etc/vintf/manifest.xml" "$TMP/vendor.raw" 2>/dev/null > "$TMP/vintf.xml" && [ -s "$TMP/vintf.xml" ]; then
        python3 - "$TMP/vintf.xml" <<'PYEOF'
import sys
p = sys.argv[1]
xml = open(p).read()
# mapper@4.0 must NOT be declared: with transport=hwbinder every GPU client
# waits forever on a service nobody provides (the R allocator service only
# serves allocator/IQtiAllocator). Undeclared (EMPTY transport) libhidl
# fast-fails and falls back to legacy gralloc0 (v37, see BUILD_NOTES).
# allocator@4.0 IS declared: the QTI allocator service serves it.
mapper_block = '''    <hal format="hidl">
        <name>android.hardware.graphics.mapper</name>
        <transport>hwbinder</transport>
        <fqname>@4.0::IMapper/default</fqname>
    </hal>
'''
block = '''    <hal format="hidl">
        <name>android.hardware.graphics.allocator</name>
        <transport>hwbinder</transport>
        <fqname>@4.0::IAllocator/default</fqname>
    </hal>
'''
changed = False
if mapper_block in xml:
    xml = xml.replace(mapper_block, '', 1)
    print("  ~ main manifest: mapper@4.0 hwbinder entry removed (legacy fast-fail path)")
    changed = True
if block in xml:
    xml = xml.replace(block, '', 1)
    print("  ~ main manifest: duplicate allocator@4.0 entry removed (fragment covers it)")
    changed = True
if changed:
    open(p, 'w').write(xml)
PYEOF
        debugfs -w -R "rm /etc/vintf/manifest.xml" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/vintf.xml /etc/vintf/manifest.xml" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif /etc/vintf/manifest.xml mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "/etc/vintf/manifest.xml" "u:object_r:vendor_configs_file:s0"
    fi
else
    echo "  ! $ALLOC_BIN missing — mapper@4.0 will deadlock SF EGL"
fi

# Send qseecom-service's stdout/stderr to /dev/kmsg. Without this the service
# dies silently: logd never creates /data/misc/logd/logcat on this device (it
# starts before /data is mounted and logd-reinit lives in the post-fs-data
# action that blocks on `vdc keymaster earlyBootEnded`).
echo "adding stdio_to_kmsg to qseecom-service rc:"
QSEE_RC=/etc/init/vendor.qti.hardware.qseecom@1.0-service.rc
if debugfs -R "cat $QSEE_RC" "$TMP/vendor.raw" 2>/dev/null > "$TMP/qsee.rc" && [ -s "$TMP/qsee.rc" ]; then
    if ! grep -q "stdio_to_kmsg" "$TMP/qsee.rc"; then
        awk '/^service qseecom-service/ { print; print "    stdio_to_kmsg"; next } { print }' \
            "$TMP/qsee.rc" > "$TMP/qsee.rc.new" && mv "$TMP/qsee.rc.new" "$TMP/qsee.rc"
        debugfs -w -R "rm $QSEE_RC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/qsee.rc $QSEE_RC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif $QSEE_RC mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "$QSEE_RC" "u:object_r:vendor_configs_file:s0"
        echo "  + $QSEE_RC (stdio_to_kmsg)"
    fi
fi

# ---- /vendor/firmware_mnt mount point --------------------------------------
# apnhlos holds every firmware blob (adsp/modem/cdsp/slpi/ipa_fws/gpu). The
# vendor partition is mounted read-only, so the mount point must exist inside
# the image. Without it firmware_class cannot find anything and the IPA driver
# panics (ipa3_load_ipa_fw -> ipa_assert -> BUG()), which is what produced the
# boot loop after the bpfloader bypass.
# (soong fsgen rejects these as PRODUCT_COPY_FILES destinations: "Path is
# outside directory", hence creating them here.)
echo "creating vendor firmware mount points:"
for dir in firmware_mnt firmware-modem dsp; do
    if ! debugfs -R "stat /$dir" "$TMP/vendor.raw" 2>/dev/null | grep -q Inode:; then
        debugfs -w -R "mkdir /$dir" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /$dir mode 040755" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /$dir uid 0" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif /$dir gid 0" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "/$dir" "u:object_r:vendor_file:s0"
        echo "  + /$dir"
    fi
done

# ---- /data + keydata mounting ----------------------------------------------
# keydata/keyrefuge hold the vaultkeeper VK ID. Their fstab lines carried
# `check`, and e2fsck refuses to skip ("3049 days without being checked"),
# so the mount failed and `nofail` swallowed it. Without /keydata,
# vaultkeeperd reports "There is no VK ID".
# /data itself is mounted by init.target.rc's own `mount_all --late`; do NOT
# add another mount_all to init.beyond1q.rc -- a second mount returns EBUSY and
# makes queue_fs_event() fail, which suppresses the nonencrypted trigger.
echo "patching fstab.qcom for keydata/keyrefuge:"
FSTAB=/etc/fstab.qcom
if debugfs -R "cat $FSTAB" "$TMP/vendor.raw" 2>/dev/null > "$TMP/fstab" && [ -s "$TMP/fstab" ]; then
    changed=0
    for part in keydata keyrefuge; do
        if grep -q "by-name/$part" "$TMP/fstab"; then
            awk -v part="$part" '
                $1 ~ ("by-name/" part) {
                    gsub(/,check/, ""); gsub(/,errors=panic/, ""); gsub(/errors=panic,/, "");
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
    fi
fi

# ---- logd restart after /data is up ----------------------------------------
# logd starts at ~6.3 s, /data mounts at ~6.6 s, so logd cannot create
# /data/misc/logd/logcat and no logcat survives a failed boot. logd-reinit
# would fix this but it lives in post-fs-data, which blocks on
# `vdc keymaster earlyBootEnded`. Restart logd right after mount_all --late.
echo "adding logd restart to init.target.rc:"
TGT_RC=/etc/init/hw/init.target.rc
if debugfs -R "cat $TGT_RC" "$TMP/vendor.raw" 2>/dev/null > "$TMP/target.rc" && [ -s "$TMP/target.rc" ]; then
    if ! grep -q "restart logd" "$TMP/target.rc"; then
        awk '/mount_all \/vendor\/etc\/fstab\.qcom --late/ { print; print "    restart logd"; next } { print }' \
            "$TMP/target.rc" > "$TMP/target.rc.new" && mv "$TMP/target.rc.new" "$TMP/target.rc"
        debugfs -w -R "rm $TGT_RC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/target.rc $TGT_RC" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif $TGT_RC mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "$TGT_RC" "u:object_r:vendor_configs_file:s0"
        echo "  + $TGT_RC (restart logd after mount_all --late)"
    fi
fi

img2simg "$TMP/vendor.raw" "$IMG"
echo "rewrote $IMG"

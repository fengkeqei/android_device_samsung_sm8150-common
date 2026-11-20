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
CONV_LINKER_CONFIG=${CONV_LINKER_CONFIG:-out/host/linux-x86/bin/conv_linker_config}
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
    #
    # v136: vendor sources MUST win over the system staging copy. A vendor blob
    # was built against the vendor variant of its deps; the A16 system variant
    # can carry extra DT_NEEDED entries that do not exist in the vendor
    # namespace (libstagefright_bufferqueue_helper.so system copy NEEDs
    # libgui.so, which broke the C2 codec HAL). Only fall back to the system
    # variant when no vendor-side copy exists at all.
    # HAL passthrough impl modules live in <arch>/hw/ and MUST be installed to
    # /<arch>/hw/. Looking only at the top level made every impl in the LIBS
    # list resolve to "UNRESOLVED", so e.g. android.hardware.memtrack@1.0-impl.so
    # never reached the image and the memtrack HAL crash-looped (which blocks
    # system_server's MemtrackProxyService and therefore boot_completed).
    local sub="" dst=""
    for sub in "" "/hw"; do
        dst="/lib64$sub"
        if [ -f "$STAGE/lib64$sub/$lib" ]; then
            install_lib "$STAGE/lib64$sub/$lib" "$dst/$lib"; got=1
        elif [ -f "$PROP/lib64$sub/$lib" ]; then
            install_lib "$PROP/lib64$sub/$lib" "$dst/$lib"; got=1
        elif [ -f "$STOCK/lib64$sub/$lib" ]; then
            install_lib "$STOCK/lib64$sub/$lib" "$dst/$lib"; got=1
        elif [ -f "$SYSSTAGE/lib64$sub/$lib" ]; then
            install_lib "$SYSSTAGE/lib64$sub/$lib" "$dst/$lib"; got=1
        fi
        dst="/lib$sub"
        if [ -f "$STAGE/lib$sub/$lib" ]; then
            install_lib "$STAGE/lib$sub/$lib" "$dst/$lib"; got=1
        elif [ -f "$PROP/lib$sub/$lib" ]; then
            install_lib "$PROP/lib$sub/$lib" "$dst/$lib"; got=1
        elif [ -f "$STOCK/lib$sub/$lib" ]; then
            install_lib "$STOCK/lib$sub/$lib" "$dst/$lib"; got=1
        elif [ -f "$SYSSTAGE/lib$sub/$lib" ]; then
            install_lib "$SYSSTAGE/lib$sub/$lib" "$dst/$lib"; got=1
        fi
        [ "$got" = 1 ] && break
    done
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
android.hidl.token@1.0.so
android.hidl.token@1.0-utils.so
libhidlmemory.so
libcamera_metadata.so
android.hardware.audio.common@4.0.so
android.hardware.security.secureclock-V1-ndk.so
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
vendor.qti.hardware.display.mapper@2.0.so
libplatformconfig.so
libdisplayconfig.qti.so
libqservice.so
libdisplaydebug.so
libsdmutils.so
libsdmcore.so
libgrallocutils.so
libgralloccore.so
libgpu_tonemapper.so
libavservices_minijail.so
libjsoncpp.so
android.hardware.gnss.measurement_corrections@1.0.so
android.system.keystore2-V1-ndk.so
android.hardware.radio@1.5.so
android.hardware.radio@1.6.so
android.hardware.camera.provider@2.5.so
android.hardware.camera.provider@2.6.so
android.frameworks.sensorservice@1.0.so
vendor.display.config@1.4.so
vendor.display.config@1.5.so
vendor.display.config@1.6.so
vendor.display.config@1.7.so
vendor.display.config@1.8.so
vendor.display.config@1.9.so
vendor.display.config@1.10.so
vendor.display.config@1.11.so
libsdedrm.so
android.hardware.memtrack@1.0.so
android.hardware.memtrack@1.0-impl.so
memtrack.msmnile.so
libdrmutils.so
libdisplaycolor.so
libsdmextension.so
android.hardware.graphics.composer@2.2.so
android.hardware.graphics.composer@2.3.so
android.hardware.graphics.composer@2.4.so
libhwc2onfbadapter.so
android.hardware.graphics.composer@2.1-resources.so
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
android.hardware.tetheroffload.config@1.0.so
android.hardware.tetheroffload.control@1.0.so
"

echo "injecting vendor HAL interface libraries into $IMG:"
for lib in $LIBS; do
    resolve_and_install "$lib"
done

# Samsung's audio.primary.msmnile.so is ELF32 and needs the 32-bit
# libaudioroute.so in /vendor/lib (a 64-bit copy in /lib64 is useless to it).
# The AOSP module is vendor_available but Soong does not ship its vendor
# variant for this product, so the 32-bit build is kept as a tree blob.
if [ -f device/samsung/sm8150-common/vendor_audio/lib/libaudioroute.so ]; then
    install_lib device/samsung/sm8150-common/vendor_audio/lib/libaudioroute.so "/lib/libaudioroute.so"
    debugfs -w -R "rm /lib64/libaudioroute.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
fi

# v136 static linker audit (link_audit_vendor.py, 1907 ELFs) proved the
# vendor namespace is NOT self-sufficient: prebuilt Samsung HALs DT_NEEDED a
# long tail of stock libs that neither the Soong graph nor the stale generated
# vendor.mk ships (qseecomd died on libxml2->libandroidicu crossing the
# namespace). This restores the v135 behavior of shipping the complete stock
# vendor lib set from vendor_libs, minus the seven libs whose AOSP-built
# variants must win (see SKIP_AOSP_BUILT below).
# NOTE: the previous `case "$lib" in $SKIPV)` form silently failed for
# newline-separated patterns under `set -u` + unquoted expansion: the list
# collapsed into one word, so nothing matched and stock libEGL/libGLESv2/
# libGLESv3 were injected anyway, which made linkerconfig abort with
# "duplicate: libEGL.so is provided by default and system in [vendor]".
# A plain string comparison per pattern is unambiguous.
skip_v() {
    local needle=$1 p
    for p in \
        android.hardware.graphics.composer@2.1.so \
        android.hardware.graphics.composer@2.1-resources.so \
        android.hardware.graphics.composer@2.2-resources.so \
        libhwc2on1adapter.so \
        libhwc2onfbadapter.so \
        libbluetooth_audio_session.so \
        android.hardware.bluetooth.audio@2.0.so \
        libstagefright_bufferqueue_helper.so \
        android.hidl.token@1.0-utils.so \
        android.hidl.token@1.0.so \
        libEGL.so \
        libGLESv2.so \
        libGLESv3.so \
        libandroid_net.so \
        libapexsupport.so \
        libbinder_ndk.so \
        liblog.so \
        libnativewindow.so \
        libselinux.so \
        libsync.so \
        libvndksupport.so \
; do
        [ "$needle" = "$p" ] && return 0
    done
    return 1
}

SKIPV_UNUSED='android.hardware.graphics.composer@2.1.so
android.hardware.graphics.composer@2.1-resources.so
android.hardware.graphics.composer@2.2-resources.so
libhwc2on1adapter.so
libhwc2onfbadapter.so
libbluetooth_audio_session.so
android.hardware.bluetooth.audio@2.0.so
libstagefright_bufferqueue_helper.so
android.hidl.token@1.0-utils.so
android.hidl.token@1.0.so
libEGL.so
libGLESv2.so
libGLESv3.so
'
# ipacm IS shipped. Do not remove it here.
#
# A previous revision of this script deleted /bin/ipacm and /etc/init/ipacm.rc
# after packaging, on the theory that the two HIDL interfaces the blob links
# (android.hardware.tetheroffload.config@1.0.so and .control@1.0.so) no longer
# exist on Android 16. That reasoning is wrong: both interface libraries are
# still built in this tree (hardware/interfaces/tetheroffload/{config,control}/1.0)
# and both are named in PRODUCT_PACKAGES in sm8150-common-vendor.mk, so they
# land in /vendor/lib64. Verified on device RF8N32EV43X: vendor.ipacm reaches
# state "running" with no linker error and no restart loop.
#
# Deleting the binary is what made the LTE investigation dead-end: with
# vendor.ipacm absent the IPA data path is never initialised and
# ril.cidManager.initiated stays 0 (stock: 1), which was repeatedly mistaken
# for an RF fault. See STATUS_20261118.md.

STOCKV=device/samsung/sm8150-common/vendor_libs
STOCKP=vendor/samsung/sm8150-common/proprietary/vendor

# Idempotency: an earlier run of this script (before the skip list was fixed)
# injected the stock EGL family into the image. Remove them so re-running the
# script converges to the correct state instead of preserving the mistake.
# linkerconfig aborts with "duplicate: libEGL.so is provided by default and
# system in [vendor]" when the stock copies are present, and that abort makes
# init fall back to a stub ld.config.txt with only /system/lib64 in the search
# path (keystore2/qseecomd then fail with "libandroidicu.so not found").
# The full set is derived from linker.config.json provideLibs (65 libs, incl.
# LLNDK_MOVED_TO_APEX_LIBRARIES) intersected with vendor_libs: every one of
# these makes linkerconfig abort with
#   "duplicate: <lib> is provided by default and system in [vendor]"
# and that abort is what makes init fall back to a stub ld.config.txt.
for d in lib64 lib; do
    for lib in \
        libEGL.so libGLESv2.so libGLESv3.so libandroid_net.so libapexsupport.so  \
        libbinder_ndk.so liblog.so libnativewindow.so libselinux.so libsync.so  \
        libvndksupport.so ; do
        debugfs -w -R "rm /$d/$lib" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    done
done

# Removing those libs is not enough: /vendor/etc/linker.config.pb was generated
# by fsgen while the libs were still present, so it still advertises them as
# "provided by vendor". linkerconfig then aborts with
#   duplicate: libandroid_net.so is provided by default and system in [vendor]
# even though the files are gone. Regenerate the pb with only the libs that
# genuinely stay vendor-only (liboemcrypto, from
# hardware/qcom-caf/common/linker.config.json).
LCV=/etc/linker.config.pb
if [ -f "$CONV_LINKER_CONFIG" ]; then
    printf '{\n  "provideLibs": [\n    "liboemcrypto.so"\n  ]\n}\n' > "$TMP/lc.json"
    if "$CONV_LINKER_CONFIG" proto -s "$TMP/lc.json" -o "$TMP/lc.pb" 2>/dev/null; then
        debugfs -w -R "rm $LCV" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/lc.pb $LCV" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "sif $LCV mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        set_selinux_label "$LCV" "u:object_r:vendor_configs_file:s0"
        echo "  ~ $LCV regenerated (provideLibs = liboemcrypto only)"
    else
        echo "  ! conv_linker_config failed" >&2
    fi
fi


# AIDL supplicant VINTF declaration, written directly into the image.
#
# wpa_supplicant links android.hardware.wifi.supplicant-V5-ndk, but
# assemble_vintf rewrites version 5 down to the highest *frozen* version (4) no
# matter whether it comes from a vintf_fragment or from DEVICE_MANIFEST_FILE.
# With 4 declared, the framework's ISupplicant lookup misses and supplicant
# dies with
#   Failed to initialize wpa_supplicant (status 255)
#   WifiNative: Failed to start supplicant
# and WiFi never turns on. Writing the fragment straight into the image keeps
# version 5 (this is the same file that was verified working on device).
SUPP_FRAG=/etc/vintf/manifest/android.hardware.wifi.supplicant.xml
cat > "$TMP/supp.xml" <<'XMLEOF'
<manifest version="1.0" type="device">
    <hal format="aidl">
        <name>android.hardware.wifi.supplicant</name>
        <version>5</version>
        <fqname>ISupplicant/default</fqname>
    </hal>
</manifest>
XMLEOF
debugfs -w -R "rm $SUPP_FRAG" "$TMP/vendor.raw" >/dev/null 2>&1 || true
debugfs -w -R "write $TMP/supp.xml $SUPP_FRAG" "$TMP/vendor.raw" >/dev/null 2>&1 || true
debugfs -w -R "sif $SUPP_FRAG mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1 || true
set_selinux_label "$SUPP_FRAG" "u:object_r:vendor_configs_file:s0"
echo "  ~ $SUPP_FRAG (ISupplicant/default @5)"

for d in lib64 lib; do
    for src in "$STOCKV/$d"/*.so; do
        [ -f "$src" ] || continue
        lib=$(basename "$src")
        skip_v "$lib" && continue
        install_lib "$src" "/$d/$lib"
    done
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


# Round-82: the stock Samsung composer@2.1-service rc must be present and the
# 2.4 wrapper rc must be gone. During bring-up the 2.1 rc was removed and an
# experimental 2.4 wrapper took over — but the 2.4 path fails composer
# resources creation, while A16 SF falls back to IComposer@2.1 exactly like
# the 29th's working boot (v41).
echo "restoring stock composer@2.1-service rc:"
STOCK_RC=$STOCK/rc/android.hardware.graphics.composer@2.1-service.rc
if [ -f "$STOCK_RC" ]; then
    debugfs -w -R "rm /etc/init/android.hardware.graphics.composer@2.4-service.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "rm /etc/init/android.hardware.graphics.composer@2.1-service.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $STOCK_RC /etc/init/android.hardware.graphics.composer@2.1-service.rc" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /etc/init/android.hardware.graphics.composer@2.1-service.rc mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/etc/init/android.hardware.graphics.composer@2.1-service.rc" "u:object_r:vendor_configs_file:s0"
    echo "  + /etc/init/android.hardware.graphics.composer@2.1-service.rc"
fi

# Round-80: QTI allocator service deps + restored libs (libdisplayqos/libsync
# SF's eglInitialize (via eglSubDriverAndroid.so) waits forever on
# android.hardware.graphics.mapper@4.0::IMapper/default. That instance is
# served by this R-style allocator service; without the binary every GPU
# client deadlocks and system_server ANRs on waitForService<ISurfaceComposer>.
# The service binary is registered eagerly via `class hal`, so the stock rc's
# missing `interface` lines don't matter. The fragment declares
# allocator@3.0/4.0 + IQtiAllocator@3.0/4.0; the same @4.0::IAllocator/default
# entry must then be REMOVED from the main manifest to avoid a duplicate.
# Round-84: QTI mapper SP-HALs (the R unified-gralloc mapper). libui's
# GraphicBufferMapper FATALs with "gralloc-mapper is missing" in the
# composer process unless an IMapper@4.0 is reachable; with
# PRODUCT_ENFORCE_VINTF_MANIFEST an undeclared interface never reaches the
# passthrough dlopen, so the impl libs AND the manifest fragment are both
# required (v44). These pair with the allocator service below.
# Round-85: libs8.so — String8(StaticLinkage) shim for Q-era vendor blobs
# (the A16 libutils dropped it; android.hardware.health@2.0-impl-2.1-samsung
# references it, so the health HAL dlopen fails and IHealth/default never
# registers — system_server then blocks in BatteryService, v45). The impl's
# DT_NEEDED "libutils.so" is repointed to the shim, whose own DT_NEEDED
# restores the real libutils closure. Shim source: vendor_libs/s8shim.c.
# Round-86: the AOSP AIDL health service. system_server prefers the AIDL
# IHealth and only falls back to HIDL, so a working AIDL service unblocks
# BatteryService regardless of the Q-era Samsung HIDL impl's symbol gaps
# (v45/v46). Built with: m android.hardware.health-service.example
OUTV=out/target/product/beyond1q/vendor
if [ -f "$OUTV/bin/hw/android.hardware.health-service.example" ]; then
    debugfs -w -R "rm /bin/hw/android.hardware.health-service.example" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $OUTV/bin/hw/android.hardware.health-service.example /bin/hw/android.hardware.health-service.example" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /bin/hw/android.hardware.health-service.example mode 0100755" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/bin/hw/android.hardware.health-service.example" "u:object_r:hal_health_default_exec:s0"
    echo "  + /bin/hw/android.hardware.health-service.example"
    for f in etc/init/android.hardware.health-service.example.rc              etc/vintf/manifest/android.hardware.health-service.example.xml; do
        dst="/$f"
        debugfs -w -R "rm $dst" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $OUTV/$f $dst" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif $dst mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "$dst" "u:object_r:vendor_configs_file:s0"
        echo "  + $dst"
    done
    LIB="android.hardware.health-V4-ndk.so"
    if [ -f "$OUTV/lib64/$LIB" ]; then
        debugfs -w -R "rm /lib64/$LIB" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $OUTV/lib64/$LIB /lib64/$LIB" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif /lib64/$LIB mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "/lib64/$LIB" "u:object_r:same_process_hal_file:s0"
        echo "  + /lib64/$LIB"
    fi
fi

# Round-87: without a file_contexts rule the boot-time restorecon resets the
# example service's label to vendor_file and init's exec fails with EACCES
# ("cannot execv ... Permission denied", v46) — same mechanism as the
# Samsung health label fix, so append the rule to the image's copy.
VFC_EX=/etc/selinux/vendor_file_contexts
EX_RULE='/(vendor|system/vendor)/bin/hw/android\\.hardware\\.health-service\\.example u:object_r:hal_health_default_exec:s0'
if debugfs -R "cat $VFC_EX" "$TMP/vendor.raw" 2>/dev/null > "$TMP/vfc_ex.txt" && [ -s "$TMP/vfc_ex.txt" ]; then
    if ! grep -qF "health-service.example" "$TMP/vfc_ex.txt"; then
        printf '%s\n' "$EX_RULE" >> "$TMP/vfc_ex.txt"
        debugfs -w -R "rm $VFC_EX" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/vfc_ex.txt $VFC_EX" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif $VFC_EX mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "$VFC_EX" "u:object_r:vendor_configs_file:s0"
        echo "  + $VFC_EX (health-service.example rule appended)"
    fi
fi

# Round-88: adb without the authorization UI (the screen is unusable during
# bring-up) plus a dontaudit for the spdaemon property avc flood that drowns
# the kmsg ring via logd.auditd's kmsg relay (v48/v49).
echo "patching vendor build.prop (adb) and vendor_sepolicy.cil (avc flood):"
if debugfs -R "cat /build.prop" "$TMP/vendor.raw" 2>/dev/null > "$TMP/bp.txt" && [ -s "$TMP/bp.txt" ]; then
    if ! grep -q "ro.adb.secure=0" "$TMP/bp.txt"; then
        printf '\n# bring-up: adb without authorization UI\nro.adb.secure=0\npersist.sys.usb.config=adb\n' >> "$TMP/bp.txt"
        debugfs -w -R "rm /build.prop" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/bp.txt /build.prop" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif /build.prop mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "/build.prop" "u:object_r:vendor_configs_file:s0"
        echo "  + /build.prop (adb)"
    fi
fi
if debugfs -R "cat /etc/selinux/vendor_sepolicy.cil" "$TMP/vendor.raw" 2>/dev/null > "$TMP/cil.txt" && [ -s "$TMP/cil.txt" ]; then
    if ! grep -q "dontaudit vendor_spdaemon" "$TMP/cil.txt"; then
        printf '\n(dontaudit vendor_spdaemon property_type (file (open getattr map read)))\n(dontaudit linkerconfig property_type (file (open getattr map read)))\n' >> "$TMP/cil.txt"
        debugfs -w -R "rm /etc/selinux/vendor_sepolicy.cil" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $TMP/cil.txt /etc/selinux/vendor_sepolicy.cil" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif /etc/selinux/vendor_sepolicy.cil mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "/etc/selinux/vendor_sepolicy.cil" "u:object_r:vendor_configs_file:s0"
        echo "  + vendor_sepolicy.cil (spdaemon/linkerconfig dontaudit)"
    fi
fi

# Round-89: bring-up probes — service state changes written straight to
# kmsg (logd's /data persistence is broken on this device, so logcat is
# always 0 bytes after reboot; kmsg survives in last_kmsg). Also force-
# start adbd when the usb config says adb, in case the ffs trigger chain
# stalls (v50).
if [ -f "$STOCK/rc/brgup.rc" ]; then
    debugfs -w -R "rm /etc/init/brgup.rc" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $STOCK/rc/brgup.rc /etc/init/brgup.rc" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /etc/init/brgup.rc mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/etc/init/brgup.rc" "u:object_r:vendor_configs_file:s0"
    echo "  + /etc/init/brgup.rc (kmsg probes + adbd kick)"
fi

echo "injecting String8 shim and patching the health impl:"
if [ -f "$STOCK/lib64/libs8.so" ]; then
    debugfs -w -R "rm /lib64/libs8.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $STOCK/lib64/libs8.so /lib64/libs8.so" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /lib64/libs8.so mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/lib64/libs8.so" "u:object_r:same_process_hal_file:s0"
    echo "  + /lib64/libs8.so"
fi
HIMPL="$PROP/lib64/hw/android.hardware.health@2.0-impl-2.1-samsung.so"
if [ -f "$HIMPL" ] && command -v python3 >/dev/null; then
    python3 - "$HIMPL" "$TMP/health_patched.so" <<'PYEOF2'
import sys
data = bytearray(open(sys.argv[1], 'rb').read())
old = b'libutils.so\x00'
assert data.count(old) == 1, 'unexpected dynstr layout'
off = data.find(old)
data[off:off+len(old)] = b'libs8.so\x00\x00\x00\x00'
open(sys.argv[2], 'wb').write(data)
print('  ~ health impl DT_NEEDED libutils.so -> libs8.so')
PYEOF2
    debugfs -w -R "rm /lib64/hw/android.hardware.health@2.0-impl-2.1-samsung.so" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $TMP/health_patched.so /lib64/hw/android.hardware.health@2.0-impl-2.1-samsung.so" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif /lib64/hw/android.hardware.health@2.0-impl-2.1-samsung.so mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "/lib64/hw/android.hardware.health@2.0-impl-2.1-samsung.so" "u:object_r:same_process_hal_file:s0"
    echo "  + patched health impl"
fi

echo "injecting QTI mapper SP-HAL impls:"
for d in lib64 lib; do
    for v in 3.0 4.0; do
        src="$PROP/$d/hw/android.hardware.graphics.mapper@$v-impl-qti-display.so"
        dst="/$d/hw/android.hardware.graphics.mapper@$v-impl-qti-display.so"
        [ -f "$src" ] || continue
        debugfs -w -R "rm $dst" "$TMP/vendor.raw" >/dev/null 2>&1 || true
        debugfs -w -R "write $src $dst" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif $dst mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif $dst uid 0" "$TMP/vendor.raw" >/dev/null 2>&1
        debugfs -w -R "sif $dst gid 0" "$TMP/vendor.raw" >/dev/null 2>&1
        set_selinux_label "$dst" "u:object_r:same_process_hal_file:s0"
        echo "  + $dst"
    done
done
MFRAG=/etc/vintf/manifest/android.hardware.graphics.mapper-impl-qti-display.xml
if [ -f "$PROP/etc/vintf/manifest/android.hardware.graphics.mapper-impl-qti-display.xml" ]; then
    debugfs -w -R "rm $MFRAG" "$TMP/vendor.raw" >/dev/null 2>&1 || true
    debugfs -w -R "write $PROP/etc/vintf/manifest/android.hardware.graphics.mapper-impl-qti-display.xml $MFRAG" "$TMP/vendor.raw" >/dev/null 2>&1
    debugfs -w -R "sif $MFRAG mode 0100644" "$TMP/vendor.raw" >/dev/null 2>&1
    set_selinux_label "$MFRAG" "u:object_r:vendor_configs_file:s0"
    echo "  + $MFRAG"
fi

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

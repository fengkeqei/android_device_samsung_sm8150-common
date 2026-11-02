#
# Copyright (C) 2020 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

COMMON_PATH := device/samsung/sm8150-common

# Old blobs have 4K-aligned load segments; skip 16K page-size check during bring-up
PRODUCT_CHECK_PREBUILT_MAX_PAGE_SIZE := false

PRODUCT_TARGET_VNDK_VERSION := 30

# Enable updating of APEXes
$(call inherit-product, $(SRC_TARGET_DIR)/product/updatable_apex.mk)

# Proprietary blobs
$(call inherit-product-if-exists, vendor/samsung/sm8150-common/sm8150-common-vendor.mk)

# Overlays
PRODUCT_PACKAGE_OVERLAYS += \
    $(COMMON_PATH)/overlay \
    $(COMMON_PATH)/overlay-lineage

PRODUCT_ENFORCE_RRO_TARGETS += *
PRODUCT_ENFORCE_RRO_EXCLUDED_OVERLAYS += \
    $(COMMON_PATH)/overlay-lineage/lineage-sdk \
    $(COMMON_PATH)/overlay-lineage/packages/apps/Snap

# Fingerprint: use hardware/samsung's AIDL IFingerprint wrapper instead of the
# stock HIDL 2.1 service. AOSP 15 can't drive the HIDL HAL correctly (an empty
# config_biometric_sensors blocks forever on the virtual HAL; a populated one
# NPEs in FingerprintProvider.scheduleInternalCleanup, Round 67). The wrapper
# dlopens libbauthserver.so directly (all 13 required ss_* symbols exist in our
# vendor blobs) and reads type/location from ro.vendor.fingerprint.* (system.prop).
PRODUCT_SOONG_NAMESPACES += hardware/samsung
# hardware/samsung's keymaster service links libskeymaster4device, which is a
# prebuilt declared in the vendor/samsung/sm8150-common namespace; that
# namespace must be visible or soong reports "undefined module".
PRODUCT_SOONG_NAMESPACES += vendor/samsung/sm8150-common
PRODUCT_PACKAGES += \
    android.hardware.biometrics.fingerprint-service.samsung

# Open-source IMS stack (krazey/ImsStack + ImsMedia fork + CarrierSettings,
# Round 71): VoLTE/VoWiFi without Samsung's proprietary IMS. See README in
# packages/modules/ImsStack. Emergency MMTEL and RCS stay gated off (defaults).
# NOTE: disabled for the first avium-16.2 bring-up; re-enable once the base
# system is fully working (ImsStack needs an Android 16 base).
#$(call inherit-product, packages/modules/ImsMedia/imsmedia.mk)
#$(call inherit-product, packages/apps/CarrierSettings/carrier_settings.mk)
#PRODUCT_PACKAGES += \
#    ImsStack \
#    Iwlan \
#    QualifiedNetworksService

# Advertise FEATURE_FINGERPRINT now that a working HAL is present.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.fingerprint.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.fingerprint.xml

# Audio 
# HotwordEnrollement app permissions
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/configs/privapp-permissions-hotword.xml:system/etc/permissions/privapp-permissions-hotword.xml

# Init
PRODUCT_PACKAGES += \
    init.qcom.rc

# Display/GPU bring-up configs (hand-written, not in the stock dump).
# NOTE: the display VINTF fragments (composer-qti-display, mapper-impl-qti-display,
# allocator-service) must NOT be installed from here — they already ship with
# hardware/qcom-caf/sm8150/display (module vintf_fragments / `required`), and a
# second copy makes kati fail with "overriding commands for target".
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/configs/vulkan/icd.d/adreno_icd.aarch64.json:$(TARGET_COPY_OUT_VENDOR)/etc/vulkan/icd.d/adreno_icd.aarch64.json

# Wi-Fi hotspot (AOSP AIDL hostapd; Samsung ships no hostapd HAL service blob,
# only a stale HIDL manifest fragment. Without this the AP fails with
# "Cannot find android.hardware.wifi.hostapd.IHostapd/default in VINTF")
PRODUCT_PACKAGES += \
    hostapd \
    hostapd_cli \
    android.hardware.wifi.hostapd.xml

# Wi-Fi tethering offload HAL (AOSP AIDL example service). Samsung ships no
# tetheroffload HAL; without it networkstack's OffloadController blocks forever
# in IOffloadConfig.getService() (HIDL wait), hanging Tethering state machine
# (Settings tethering page crashes, AP toggle stuck).
# A16 note: the example service now ships as a vendor APEX.
PRODUCT_PACKAGES += \
    com.android.hardware.tetheroffload

# Audio playback capture (screen record internal audio): the LOS ROM already
# ships the r_submix audio HAL module, but not its runtime dependency
# libnbaio_mono (frameworks/av, vendor lib). Without it loadHwModule(r_submix)
# fails with -19 and SystemUI screen recording aborts with
# "could not register audio policy".
PRODUCT_PACKAGES += \
    libnbaio_mono

# OTA Updater
AB_OTA_UPDATER := false

# NFC: Android 15 provides NFC stack via com.android.nfc APEX;
# only vendor blobs (libnfc-nci etc.) are shipped.

# Power (QTI AIDL HAL, source-built)
$(call inherit-product-if-exists, vendor/qcom/opensource/power/power-vendor-product.mk)

# Recovery
PRODUCT_PACKAGES += \
    fastbootd \
    init.recovery.qcom.rc

# Sensors (legacy HIDL impl disabled: libhidltransport removed in 22.2)

# Telephony
PRODUCT_PACKAGES += \
    telephony-ext

PRODUCT_BOOT_JARS += \
    telephony-ext

# Trust HAL

# keystore2 needs a "default" keymaster instance, and vold needs gatekeeper.
#
# keymaster is the STOCK binary, installed by
# vendor/samsung/sm8150-common/sm8150-common-vendor.mk: it links
# libskeymaster4device and calls skeymaster::CreateSKeymasterDevice(TEE), which
# is the only implementation that can unwrap the TEE-bound FBE key. Its rc also
# creates /mnt/vendor/efs/DAK and fixes gakkeybox permissions.
#
# Do NOT use the AOSP android.hardware.keymaster@4.0-service source build: it is
# a *software* keymaster (SecurityLevel::SOFTWARE), so boot stalls in init's
# early_hal phase with
#   "Could not find 'android.hardware.keymaster@4.0::IKeymasterDevice/default'"
# repeating once per second while vold/zygote/surfaceflinger never start.
# Samsung keymaster blobs link the legacy sk_delete / ASN1_INTEGER_get_uint32
# crypto API that upstream BoringSSL dropped; those two symbols are restored in
# external/boringssl so the blobs load against the A16 system libcrypto.
PRODUCT_PACKAGES += \
    android.hardware.gatekeeper@1.0-impl \
    android.hardware.gatekeeper@1.0-service

# Keystore2 (A16) only talks KeyMint AIDL, but vendor ships only keymaster@4.0
# (HIDL, TEE). Add the AOSP software KeyMint service so keystore2 can start and
# vold stops stalling on android.security.maintenance. SOFTWARE backend cannot
# unwrap a TEE-bound FBE key, but /data is unencrypted after dropping ice, so
# this is the quick bring-up path (TEE delegation is the longer-term fix).
PRODUCT_PACKAGES += \
    android.hardware.security.keymint-service

# Hwcomposer: the vendor 2.4 service exits immediately, so use the AOSP 2.1
# service which drives the legacy hwcomposer.msmnile.so via libhwc2on1adapter.
PRODUCT_PACKAGES += \
    android.hardware.graphics.composer@2.1-service

# Samsung ships pre-Treble-era HAL versions (contexthub@1.0, memtrack@1.0,
# radio@1.4, soundtrigger@2.1, tetheroffload.control@1.0, ...) that the AOSP
# framework compatibility matrix (FCM >= 5) marks as deprecated, so the
# in-build checkvintf --check-compat fails. This mirrors stock Samsung
# behaviour: stock builds do not enforce the VINTF manifest either.
PRODUCT_ENFORCE_VINTF_MANIFEST_OVERRIDE := false

# Libraries the Samsung TEE HALs link against (pruned from the blob list as
# "platform libs"); installed into /vendor/lib64 as vendor_available variants.
PRODUCT_PACKAGES += \
    android.hardware.keymaster@4.1 \
    android.hidl.memory@1.0 \
    android.hidl.memory.token@1.0 \
    libhidlmemory

# A16 removed VNDK, so vendor processes can no longer resolve libraries from
# /system/lib64 (vendor namespace only searches /odm/lib*, /vendor/lib* and
# /vendor/lib*/hw|egl). Stock vendor HAL blobs link AOSP HIDL interface
# libraries that live in /system/lib64, and with DISABLE_DEPS the prebuilt
# binaries do not declare those dependencies, so soong never builds the vendor
# variants and 19 HAL services die in the linker ("CANNOT LINK EXECUTABLE ...
# library not found"), including health@2.1 whose absence blocks
# BatteryService.onStart on the system_server main thread (boot 2026-10-30).
# hidl_interface modules are vendor_available, so adding them to
# PRODUCT_PACKAGES installs the vendor variant (verified with
# android.hidl.memory@1.0, which lands in vendor/lib64 the same way).
PRODUCT_PACKAGES += \
    android.hardware.camera.common@1.0 \
    android.hardware.drm@1.0 \
    android.hardware.drm@1.3 \
    android.hardware.gnss@1.0 \
    android.hardware.health@2.1 \
    android.hardware.neuralnetworks@1.0 \
    android.hardware.usb@1.0 \
    android.hidl.allocator@1.0 \
    libcamera_metadata \
    libprocessgroup

# Register the device tree soong namespace: device/samsung/sm8150-common
# Android.bp provides the libqti-perfd-client prebuilt module below.
PRODUCT_SOONG_NAMESPACES += device/samsung/sm8150-common

# Stock vendor library with no AOSP module and nothing else in the build graph
# providing it (QTI perfd client stub, pruned from the blob list). Installed as
# the cc_prebuilt_library_shared module in Android.bp because kati rejects ELF
# files in PRODUCT_COPY_FILES.
# libjson (external/json-c), libwifi-hal (frameworks/opt/net/wifi), librmnetctl
# (vendor/qcom/opensource/dataservices) and vendor.qti.hardware.perf@2.0
# (vendor/qcom/opensource/interfaces) are already installed from source — a
# second copy here makes kati fail with "overriding commands for target".
PRODUCT_PACKAGES += \
    libqti-perfd-client_prebuilt

# Replace stock vendor fstab with ours (no /system or /odm entry: /system is the
# SAR rootfs and there is no odm partition)
PRODUCT_COPY_FILES += \
    device/samsung/beyond1q/fstab.qcom:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.qcom

# Device node permission rules (restores /dev/kgsl-3d0 etc. for the GPU)
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/ueventd.rc:$(TARGET_COPY_OUT_VENDOR)/ueventd.rc

# v116: debug_logcat.rc is NOT installed any more. It ran "start logcatd"
# from post-fs-data, and logcatd reading "-b all" is the slow reader that
# makes logd emit 13k+ "Skipping entries from slow reader" lines per boot,
# which evicts the entire early boot window from the kmsg ring buffer.
# usbdbg.sh writes the USB state to /data instead (see romfix.rc).

# Consolidated bring-up fixes (metadata tmpfs, adb composition, backlight,
# GPU firmware labels). See BUILD_NOTES.md v114.
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/romfix.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/romfix.rc

# USB/adb state snapshots to /data (survives the flooded kmsg ring buffer).
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/usbdbg.sh:$(TARGET_COPY_OUT_VENDOR)/bin/usbdbg.sh

# Restores the vendor files that proprietary-files.txt lists but the stale
# generated makefiles (vendor/samsung/sm8150-common/{Android.bp,vendor.mk},
# last regenerated 2026-10-27) never covered. This is what was keeping
# init.qcom.usb.rc -- and therefore adb -- out of the vendor image.
$(call inherit-product, $(COMMON_PATH)/vendor_restore.mk)

# NOTE: /vendor/{firmware_mnt,firmware-modem,dsp} mount points cannot be created
# through PRODUCT_COPY_FILES (soong fsgen rejects those destination names), so
# they are added to the built vendor image by
# device/samsung/sm8150-common/fix_vendor_mountpoints.sh

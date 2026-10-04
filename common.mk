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
PRODUCT_PACKAGES += \
    android.hardware.biometrics.fingerprint-service.samsung

# Open-source IMS stack (krazey/ImsStack + ImsMedia fork + CarrierSettings,
# Round 71): VoLTE/VoWiFi without Samsung's proprietary IMS. See README in
# packages/modules/ImsStack. Emergency MMTEL and RCS stay gated off (defaults).
$(call inherit-product, packages/modules/ImsMedia/imsmedia.mk)
$(call inherit-product, packages/apps/CarrierSettings/carrier_settings.mk)
PRODUCT_PACKAGES += \
    ImsStack \
    Iwlan \
    QualifiedNetworksService

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
PRODUCT_PACKAGES += \
    android.hardware.tetheroffload-service.example

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

# keystore2 needs a "default" keymaster instance (the vendor only ships the
# strongbox one), and vold needs gatekeeper; both are provided by AOSP sources.
# The -impl library is the HIDL passthrough bridge: without it the service dies
# with "Could not get passthrough implementation" (exit 1) and, since
# hwservicemanager retries every second, the 4 crashes trip RescueParty and
# block boot entirely.
PRODUCT_PACKAGES += \
    android.hardware.gatekeeper@1.0-impl \
    android.hardware.gatekeeper@1.0-service \
    android.hardware.keymaster@4.0-service

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
# "platform libs"); fix_vendor_mountpoints.sh copies them into the vendor image.
PRODUCT_PACKAGES += \
    android.hardware.keymaster@4.1 \
    android.hidl.memory@1.0 \
    android.hidl.memory.token@1.0 \
    libhidlmemory

# Replace stock vendor fstab with ours (no /system or /odm entry: /system is the
# SAR rootfs and there is no odm partition)
PRODUCT_COPY_FILES += \
    device/samsung/beyond1q/fstab.qcom:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.qcom

# Device node permission rules (restores /dev/kgsl-3d0 etc. for the GPU)
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/ueventd.rc:$(TARGET_COPY_OUT_VENDOR)/ueventd.rc

# Temporary DRM diagnostics (remove once display boots)
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/debug_dri.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/debug_dri.rc

# Enable the TSP FOD area so touches in the sensor region reach qbt2000
# (see debug_fod.rc; reference tree: init.udfps.rc behind TARGET_HAVE_FOD)
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/debug_fod.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/debug_fod.rc

# Start logcatd early so boot failures can be read from recovery
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/debug_logcat.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/debug_logcat.rc

# NOTE: /vendor/{firmware_mnt,firmware-modem,dsp} mount points cannot be created
# through PRODUCT_COPY_FILES (soong fsgen rejects those destination names), so
# they are added to the built vendor image by
# device/samsung/sm8150-common/fix_vendor_mountpoints.sh

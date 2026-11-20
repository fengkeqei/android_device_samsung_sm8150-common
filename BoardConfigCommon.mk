#
# Copyright (C) 2020-2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

BOARD_VENDOR := samsung
COMMON_PATH := device/samsung/sm8150-common

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a76

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a76

# 64-bit apps
TARGET_SUPPORTS_64_BIT_APPS := true

# v124: 32-bit support. Without this, TARGET_CPU_ABI_LIST_32_BIT stays empty
# (build/make/core/board_config.mk:375), so no 32-bit variant of anything is
# built -- including libhwbinder. The stock Samsung vendor HALs are 32-bit
# ELFs compiled against Android 11 (API 30) libbase/libcrypto, and they fail
# on A16 with "cannot locate symbol" / ASN1 NULL dereference because the
# 64-bit A16 libraries have different internal layouts. Building the 32-bit
# world lets those HALs link against the 32-bit libs they were compiled
# against.
TARGET_SUPPORTS_32_BIT_APPS := true

# Audio
USE_XML_AUDIO_POLICY_CONF := 1

# v124: soundtrigger impl multilib. hardware/interfaces/soundtrigger/2.0/
# default/Android.bp hardcodes compile_multilib: "32" for
# android.hardware.soundtrigger@2.0-impl and only overrides it via the
# "soundtrigger" soong config namespace's audioserver_multilib value, which
# comes from AUDIOSERVER_MULTILIB. Leaving it unset produced only a 32-bit
# impl, so the 64-bit service binary could not load it. "first" means
# "prefer the primary arch", i.e. arm64 here.
AUDIOSERVER_MULTILIB := first

# Bootloader
TARGET_BOOTLOADER_BOARD_NAME := msmnile
TARGET_NO_BOOTLOADER := true
TARGET_USES_UEFI := true

# Charger
BOARD_CHARGER_ENABLE_SUSPEND := true

# VINTF: HAL declarations live in runtime fragments under
# /vendor/etc/vintf/manifest/ (from the blob dump and source HAL modules).
# The device manifest is intentionally minimal; validation is skipped to
# avoid duplicate-requirement conflicts with those fragments.
#
# manifest_stock_backfill.xml = manifest_stock_shell.xml header + los_backfill.xml
# HAL declarations, merged into one file (the proven-good combo that
# fix_vendor_mountpoints.sh used to inject at runtime). manifest_proven.xml was
# a REGRESSION (8 duplicate HAL declarations -> NULL VINTF -> 400+ crashes), so
# do NOT point DEVICE_MANIFEST_FILE back at it.
DEVICE_MANIFEST_FILE := $(COMMON_PATH)/manifest_stock_backfill.xml
DEVICE_MANIFEST_SKIP_VALIDATION := true
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE := $(COMMON_PATH)/device_framework_matrix.xml

# Kernel
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_KERNEL_IMAGE_NAME := Image-dtb
BOARD_KERNEL_PAGESIZE := 4096
BOARD_KERNEL_SEPARATED_DTBO := true
TARGET_KERNEL_APPEND_DTB := true
TARGET_KERNEL_ARCH := arm64
TARGET_KERNEL_CLANG_COMPILE := true
TARGET_KERNEL_CLANG_VERSION := r563880c
TARGET_KERNEL_CONFIG := beyond1qlte_usa_single_defconfig
TARGET_KERNEL_SOURCE := kernel/samsung/sm8150
# clang 19 raises many new warnings on 4.14 sources; keep the build going
# lld cannot link MODVERSIONS PREL32 relocs against absolute __crc_ symbols:
# use GNU ld (2.27, same as NDK r16b flow) but keep the integrated assembler
TARGET_KERNEL_LLVM_BINUTILS := false
# 4.14 MODVERSIONS __crc_ PREL32 relocs cannot be linked by lld: pin the kernel
# link to GNU ld 2.27 (in PATH via the gcc-4.9 prebuilts) while keeping clang
# + integrated assembler. Presetting KERNEL_CC also bypasses kernel.mk's
# hardcoded LD=ld.lld default.
KERNEL_CC := CC=clang LD=aarch64-linux-android-ld
TARGET_KERNEL_ADDITIONAL_FLAGS := KCFLAGS=-Wno-error LLVM=1 LLVM_IAS=1 AR=llvm-ar LD=aarch64-linux-android-ld

# Boot image (values from stock G9730ZCU8HZE1 boot.img header)
BOARD_BOOTIMG_HEADER_VERSION := 1
BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_RAMDISK_OFFSET := 0x01000000
BOARD_SECOND_OFFSET := 0x00f00000
BOARD_TAGS_OFFSET := 0x01e00000
BOARD_DTB_OFFSET := 0x01f00000
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOTIMG_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS += --base $(BOARD_KERNEL_BASE)
BOARD_MKBOOTIMG_ARGS += --kernel_offset $(BOARD_KERNEL_OFFSET)
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset $(BOARD_RAMDISK_OFFSET)
BOARD_MKBOOTIMG_ARGS += --second_offset $(BOARD_SECOND_OFFSET)
BOARD_MKBOOTIMG_ARGS += --tags_offset $(BOARD_TAGS_OFFSET)
BOARD_KERNEL_CMDLINE := console=null androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=2048 androidboot.usbcontroller=a600000.dwc3 firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7 sec_log=0x200000@0xC1600000 sec_dbg=0x1FF000@0xC1400000 sec_dbg_ex_info=0x1000@0xC15FF000 sec_debug.enable=0 sec_debug.enable_user=0 androidboot.selinux=permissive

# Partitions (from stock layout, non-dynamic; measured on device)
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_DTBOIMG_PARTITION_SIZE := 10485760
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 82825216
BOARD_VENDORIMAGE_PARTITION_SIZE := 1379926016

# DTBO: the stock Samsung DTBO carries an fstab overlay that mounts the OMC
# partition (sda27) over /product:
#   product { dev = ".../by-name/product"; fsmgr_flags = "wait,verify,avb"; }
# That is A12 carrier data, and on this A16 tree it covers the merged
# /system/product content, so the product SELinux stamp becomes unreadable,
# init sees "plat/product/system_ext sha256 differ", recompiles policy, fails
# on the missing mapping file and lands in InitFatalReboot -> kernel panic ->
# download mode. The prebuilt below is the same DTBO with that node removed
# (FDT decompiled, node deleted, recompiled, AVB footer re-added).
# Do NOT replace it with the stock dtbo.img, and do not let the kernel DTBO
# generation run: the in-tree A12 dts still carries the node.
# BOARD_PREBUILT_DTBOIMAGE keeps its default intermediates path - the custom
# mk copies the tree prebuilt there instead of running mkdtboimg.
BOARD_CUSTOM_DTBOIMG_MK := $(COMMON_PATH)/dtboimage.mk

# Partition sizes measured on device (system was repartitioned to 5.1GB)
BOARD_SYSTEMIMAGE_PARTITION_SIZE := 5510266880
BOARD_CACHEIMAGE_PARTITION_SIZE := 335544320
BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE := ext4

# Vendor security patch level.
# The stock SM-G9730 firmware this port is based on (G9730ZCU8HWE1) reports
# 2023-03-01 for both ro.build.version.security_patch and
# ro.vendor.build.security_patch. Without VENDOR_SECURITY_PATCH the vendor
# property is empty and Settings > About phone shows a blank patch level.
VENDOR_SECURITY_PATCH := 2023-03-01

# Platform
BOARD_USES_QCOM_HARDWARE := true
TARGET_BOARD_PLATFORM := msmnile

# Partitions
BOARD_FLASH_BLOCK_SIZE := 262144
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
# No odm partition on this device: odm content lives in the vendor image, which
# matches the /odm/* -> /vendor/odm/* symlinks in the system image.
TARGET_COPY_OUT_ODM := vendor/odm
TARGET_COPY_OUT_PRODUCT := system/product
TARGET_COPY_OUT_SYSTEM_EXT := system/system_ext
TARGET_COPY_OUT_VENDOR := vendor

# Properties
TARGET_PRODUCT_PROP += $(COMMON_PATH)/product.prop
TARGET_VENDOR_PROP += $(COMMON_PATH)/system.prop

# Recovery
BOARD_HAS_DOWNLOAD_MODE := true
BOARD_INCLUDE_RECOVERY_DTBO := true
TARGET_NO_RECOVERY := false
TARGET_RECOVERY_PIXEL_FORMAT := BGRA_8888
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USES_MKE2FS := true

# Releasetools
TARGET_RELEASETOOLS_EXTENSIONS := $(COMMON_PATH)/releasetools

# Root filesystem
TARGET_FS_CONFIG_GEN := $(COMMON_PATH)/config.fs

# Samsung vendor blobs (proprietary-files.txt) ship .so/.bin via PRODUCT_COPY_FILES.
# A16's check-non-elf-file-timestamps rejects ELF files copied that way (it wants
# cc_prebuilt_library_shared); that's a non-starter for a blob dump, so disable it.
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
BOARD_ROOT_EXTRA_FOLDERS := \
    carrier \
    dqmdbg \
    efs \
    keydata \
    keyrefuge \
    metadata \
    optics \
    prism \
    spu \
    omr

# SELinux
include device/qcom/sepolicy_vndr/SEPolicy.mk

SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += \
    device/samsung_slsi/sepolicy/common/private \
    $(COMMON_PATH)/sepolicy/private
# ImsMedia fork SELinux policies (Round 71 IMS bring-up)
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += \
    packages/modules/ImsMedia/sepolicy/system_ext/private

SYSTEM_EXT_PUBLIC_SEPOLICY_DIRS += \
    device/samsung_slsi/sepolicy/common/public \
    $(COMMON_PATH)/sepolicy/public

BOARD_VENDOR_SEPOLICY_DIRS += \
    device/samsung_slsi/sepolicy/common/vendor \
    $(COMMON_PATH)/sepolicy/vendor

# Verified Boot
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --set_hashtree_disabled_flag
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --set_verification_disabled_flag
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA4096
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 1
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1

# Wi-Fi
# v126: this device is Broadcom BCM4375 over PCIe, NOT Qualcomm wcn3990.
# Evidence from the running kernel:
#   dhd_wlan_init: START / WLAN_EN: GPIO 65 / Call msm_pcie_enumerate
#   dhd_sync_with_dongle: GET_REVINFO device 0x4470, vendor 0x14e4,
#                         chipnum 0x4375
#   iw dev wlan0 scan  -> real APs with SSID / RSSI
#
# BOARD_WLAN_DEVICE only decides which vendor implementation gets
# whole_static_libs'd into libwifi-hal
# (frameworks/opt/net/wifi/libwifi_hal/Android.bp, defaults
# libwifi_hal_vendor_impl_defaults). With "qcwcn" the qcom HAL is not linked
# here, so libwifi-hal carries only the fallback stub whose
# init_wifi_vendor_hal_func_table returns WIFI_ERROR_NOT_SUPPORTED.
# WifiLegacyHalFactory::getHals() then yields an empty list,
# Wifi::startInternal fails on `legacy_hals_.empty()`, and the HAL loops
# started/stopped every few ms until WifiSelfRecovery disables wifi.
BOARD_WLAN_DEVICE := bcmdhd
BOARD_HOSTAPD_DRIVER := NL80211
BOARD_HOSTAPD_PRIVATE_LIB := lib_driver_cmd_$(BOARD_WLAN_DEVICE)
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
BOARD_WPA_SUPPLICANT_PRIVATE_LIB := lib_driver_cmd_$(BOARD_WLAN_DEVICE)
WIFI_DRIVER_DEFAULT := bcmdhd
WPA_SUPPLICANT_VERSION := VER_0_8_X

# v132fix: vendor wpa_supplicant must install its AIDL ISupplicant service rc.
# Without this the flag-guarded LOCAL_INIT_RC block in
# external/wpa_supplicant_8/wpa_supplicant/Android.mk never fires -> no
# supplicant service -> WiFi UI toggle does nothing.
WIFI_HIDL_UNIFIED_SUPPLICANT_SERVICE_RC_ENTRY := true

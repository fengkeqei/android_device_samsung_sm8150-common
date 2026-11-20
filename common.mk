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
# v129: radio-service.compat removed. It aborts at startup because
# km_compat-style compat requires HIDL IRadio@1.5+ while Samsung's
# libril_sem.so only implements up to @1.4 -- restart-storm every boot.
# Telephony still works through Samsung's own rild (ril-daemon/ril-daemon1);
# re-enable only after building a HIDL->AIDL shim against @1.4.
PRODUCT_PACKAGES += \
    android.hardware.biometrics.fingerprint-service.samsung \
    android.hardware.vibrator-service.avium

# Avium beyond1q: Samsung's libril_sem.so only reports RADIO_STATE_CHANGED and
# its OEM notifications through an ISehBridge indication that a client process
# must register (RIL_RegisterSehBridge). Without that client the rild logs
#     BuildUnsolicited: IPC message 20. truncated.
#     secOemNoti: sehBridgeService[0]->mSehBridgeIndication == NULL
# for every single indication (89/89 dropped on a clean boot), keeps its
# internal device-ready state at NOT_CONNECTED, and consequently never calls
# InitiateNetworkSelection -- the modem is never told to search, so there is no
# signal, no registration, no LTE and no VoLTE.
# hardware/samsung's sehradiomanager is exactly that client; its rc marks the
# service disabled and starts it from on property:sys.boot_completed=1.
PRODUCT_PACKAGES += \
    sehradiomanager

# IMS stack: REMOVED 2026-11-20 (temporarily, for an A/B experiment).
#
# The open-source stack (krazey/ImsStack + ImsMedia fork) is not part of the
# stock platform and was suspected of interfering with modem network
# acquisition. Disabling the three packages at runtime
# (pm disable com.android.imsstack / .telephony.imsmedia / .imsserviceentitlement)
# did NOT change the symptom: modem still reported
#   SetDataRteRegStatus: [PS] ... lte reg [0] ... RSSI level = 0x0000
# so the stack is not the cause. This block is kept commented out only so the
# experiment is reproducible; re-enable by uncommenting.
#
# $(call inherit-product, packages/modules/ImsMedia/imsmedia.mk)
# $(call inherit-product, packages/apps/CarrierSettings/carrier_settings.mk)
# PRODUCT_PACKAGES += \
#     ImsStack \
#     Iwlan \
#     QualifiedNetworksService
#
# $(call soong_config_set_bool,imsstack_namespace,use_android16_telephony_compat,true)

# Advertise FEATURE_FINGERPRINT now that a working HAL is present.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.fingerprint.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.fingerprint.xml

# Samsung telephony component injection.
#
# Samsung's RIL (libsec-ril.so) reports registration/signal data in a
# non-standard layout. AOSP's ServiceStateTracker parses it with stock
# assumptions and produces garbage:
#   GetVoiceSysInfo: regState(2)[REGISTERED], voiceRte(0)[no RAT]
#   UpdateVoiceRte: 1x reg[2], gsm reg[2], wcdma reg[2], lte reg[2], hdr reg[2], Td reg[2]
#   RSSI level = 0x0000 - LTE: 0, EVDO: 0, CDMA: 0, GSM: 0, NR5G: 0
# All six RATs -- including the CDMA-only 1x/hdr/Td -- reporting "registered" at
# once is physically impossible, which is the tell that the parse is wrong and
# not the modem. The framework then renders OUT_OF_SERVICE, so the stock ROM's
# IN_SERVICE + rsrp=-77 never appears.
#
# AOSP has a supported hook for exactly this: PhoneGlobals calls
#   TelephonyComponentFactory.getInstance().injectTheComponentFactory(parser)
# on R.xml.telephony_injection, whose stock AOSP content is empty (package=""
# jar=""). Samsung ships an RRO overlay (SemTelephony_RIL.apk) that replaces
# that XML, pointing at their own factory classes.
#
# The overlay does NOT work here. It was built for Android 12 and assigns
# xml/telephony_injection the resource id 0x7f010000, while A16's TeleService
# assigns it 0x7f140014. RRO replaces resources by exact id, so the overlay
# installs, reports STATE_ENABLED and idmaps cleanly while replacing nothing
# (verified on device: dumpsys overlay shows mState=STATE_ENABLED, and
# logcat has no "Total components injected" line).
#
# So the mapping is written directly into the framework source instead:
#   packages/services/Telephony/res/xml/telephony_injection.xml
# Only the jar is installed from here.
PRODUCT_COPY_FILES += \
    vendor/samsung/sm8150-common/proprietary/system/framework/sem-telephony-common.jar:system/framework/sem-telephony-common.jar

# Audio 
# HotwordEnrollement app permissions
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/configs/privapp-permissions-hotword.xml:system/etc/permissions/privapp-permissions-hotword.xml

# Init
PRODUCT_PACKAGES += \
    init.qcom.rc

# FOD (fingerprint-on-display) enable for the QBT2000 under-display sensor.
# The TSP touch controller must be told to route touches in the fingerprint
# area to the fingerprint driver; without it enroll/auth never see a finger
# (the sensor stays idle and the TEE WAIT_INTERRUPT opcode times out).
# sysfs write is volatile -> re-applied on every boot.
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/debug_fod.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/debug_fod.rc \
    $(COMMON_PATH)/fingerprint_fw_aliases.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/fingerprint_fw_aliases.rc \
    $(COMMON_PATH)/fp_fw_alias.sh:$(TARGET_COPY_OUT_VENDOR)/bin/fp_fw_alias.sh \
    $(COMMON_PATH)/fix_vk_keydata.sh:$(TARGET_COPY_OUT_VENDOR)/bin/fix_vk_keydata.sh

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

# v126: Wi-Fi HAL service. The Samsung android.hardware.wifi@1.0-service HIDL
# blob (proprietary-files.txt, DISABLE_DEPS) aborts 120 ms into start():
#   wifi_legacy_hal.cpp:363
#   Check failed: global_func_table_.wifi_initialize && !global_handle_ ...
# The blob was compiled from the Android-11 hardware/interfaces/wifi/1.4/
# default tree and calls into A16's libwifi-hal, whose wifi_hal_fn layout
# differs; the framework has also moved to the AIDL
# android.hardware.wifi.IWifi service. android.hardware.wifi-service is the
# upstream AIDL default (hardware/interfaces/wifi/aidl/default) built against
# libwifi-hal, which this board configures for Broadcom (BCM4375/PCIe dhd)
# via BOARD_WLAN_DEVICE := bcmdhd.
# Its rc reuses the vendor.wifi_hal_legacy service name, which is why the
# Samsung blob binary + rc + vintf fragment are all commented out in
# proprietary-files.txt.
#
# v126 also: wpa_supplicant. Without it the framework's
#   WifiNative: Failed to connect to supplicant
#   WifiNative: Failed to start supplicant
#   SupplicantStaIfaceHal: Internal ISupplicantStaIfaceHal instance does not exist
# makes WifiClientModeManager fail right after CMD_SWITCH_TO_CONNECT_MODE:
#   WifiActiveModeWarden: ClientModeManager start failed!
#   HalDevMgr: removeIfaceInternal: iface(name)=wlan0
# so the STA iface is torn down immediately and wifi never turns on, even
# though the vendor HAL itself is healthy
# (retrieveIfaceHandles: adding 'wlan0'/'swlan0'/'p2p0').
# external/wpa_supplicant_8/wpa_supplicant/Android.mk defines the module as
# "wpa_supplicant" and carries
#   LOCAL_INIT_RC=aidl/android.hardware.wifi.supplicant-service.rc
# so selecting the module brings both the /vendor/bin/hw/wpa_supplicant
# binary and the AIDL ISupplicant service definition.
# v132bw41c: use the SYSTEM wpa_supplicant_avium twin instead of the vendor
# wpa_supplicant. The AIDL ISupplicant service must register on /dev/binder
# (no vendor-AIDL bridge on this bp4a base); a vendor-domain wpa_supplicant
# registers on vndbinder and system_server never sees it.
PRODUCT_PACKAGES += \
    android.hardware.wifi-service \
    android.hardware.wifi.supplicant-V5-ndk \
    wpa_supplicant_avium \
    wpa_supplicant.conf

# System-domain wpa_supplicant rc (registers ISupplicant on /dev/binder).
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/wifi_supplicant_avium.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/wifi_supplicant_avium.rc

# v129: Bluetooth HAL — bluetooth_hal backend, NOT the AOSP emulator one.
#
# History: v127 packaged android.hardware.bluetooth-service.default
# (hardware/interfaces/bluetooth/aidl/default). That implementation only opens
# a tty (default /dev/hvc5, overridable via vendor.ser.bt-uart) and does no
# chip bring-up. On this board the controller is a Broadcom BCM4375 whose BT_EN
# is a GPIO owned by the kernel driver bcm4361.c, and whose firmware must be
# loaded over HCI vendor commands before any HCI traffic works. Driving the
# UART with the controller unpowered hard-hung the AP: every Android boot ended
# in a silent reset right after "opening hci interface 0" (~18 s in), with no
# pstore/last_kmsg/tombstone written -- an AP watchdog bite.
#
# AOSP ships the correct implementation: hardware/interfaces/bluetooth/
# bluetooth_hal. It provides
#   - transport/uart_h4/transport_uart_h4.cc   H4 framing over a tty
#   - chip/chip_provisioner.cc                 Broadcom VSC firmware download
#                                              (0xFC79 chip id, 0xFC18 baud,
#                                               0xFC72 fast download, 0xFC2E
#                                               minidrv, 0xFC4E launch ram)
#   - config/hal_config_loader.cc              reads /vendor/etc/bluetooth/hal_config.json
#   - rfkill lookup by type "bluetooth"        toggles BT_EN via the kernel
#                                              (rfkill0 "bcm4361 Bluetooth")
# but it is a static library with no service entry point in the tree. v129 adds
# one (service/service_main.cpp) plus hal_config.json / firmware_config.json.
#
# Verified on device before wiring this up:
#   /sys/class/rfkill/rfkill0  name="bcm4361 Bluetooth"  soft=1
#   echo 0 > .../soft  =>  dmesg "[BT] Bluetooth Power On (69)"
# i.e. the kernel side of the power sequence works; it was simply never used.
# [v129] android.hardware.bluetooth@1.0-impl is the passthrough impl for the
# HIDL bluetooth path. android.hardware.bluetooth@1.0-service registers via
# defaultPassthroughServiceImplementation, which dlopens this library from
# /vendor/lib*/hw/ and fetches HIDL_FETCH_IBluetoothHci. It wraps
# vendor_interface.cc -> libbt-vendor.so, i.e. the Android 15
# firmware-download path. (Keep this comment above the assignment: a '#' line
# inside a backslash-continued PRODUCT_PACKAGES list would become part of the
# variable value.)
# v130: AIDL 版蓝牙 HAL（android.hardware.bluetooth-service.bt）从镜像里去掉。
# A16 蓝牙栈按 VINTF 声明选后端：只要 AIDL 声明存在，hci_backend_aidl 就会
# 无限等待 bluetooth_hal/chip_provisioner（b/卡死根因）。删除服务 + 声明后，
# 栈走 "falling back to HIDL" 路径，由 android.hardware.bluetooth@1.0-service
# + @1.0-impl（dlopen libbt-vendor.so）完成上电和固件下载 —— 即 Android 15
# 的原路，已实测固件 0.93s 下载成功、栈 ON。
PRODUCT_PACKAGES += android.hardware.bluetooth@1.0-impl
PRODUCT_PACKAGES += android.hardware.bluetooth@1.0-service

PRODUCT_COPY_FILES += \
    device/samsung/sm8150-common/bluetooth/hal_config.json:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth/hal_config.json \
    device/samsung/sm8150-common/bluetooth/firmware_config.json:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth/firmware_config.json

# v127: AIDL vibrator HAL.
#
# Android 16's framework only talks AIDL:
#   frameworks/base/services/core/java/com/android/server/vibrator/HalNativeHandler.java
# imports android.hardware.vibrator.IVibrator / IVibratorManager. The Samsung
# service (sec-vibrator-2-2) does run and registers all of its HIDL instances
#   android.hardware.vibrator@1.0..1.3::IVibrator/default
#   vendor.samsung.hardware.vibrator@2.0..2.2::ISehVibrator/default
# but HIDL is invisible to A16's VibratorManagerService, so the device had no
# haptics:
#   service check android.hardware.vibrator.IVibrator/default        -> not found
#   service check android.hardware.vibrator.IVibratorManager/default -> not found
#
# The AOSP implementation in hardware/interfaces/vibrator/aidl/default is used
# with a sysfs backend added to Vibrator.cpp: it writes to
# /sys/class/timed_output/vibrator/enable (the kernel's standard timed-output
# node, wired up by this device's Samsung vibrator driver) and to .../intensity
# for setAmplitude. The stock implementation only kept a software timer and
# never touched hardware.
PRODUCT_PACKAGES += \
    android.hardware.vibrator-service.example

# v127: sensor HAL (auto-rotation, accelerometer, gyro, proximity, ...).
#
# The hardware was always there -- the kernel threads [SENSORS_CNTL],
# [SENSORS_DATA], [SENSORS_CMD], [SENSORS_DCI], [SENSORS_DCI_CMD] are running
# and sscrpcd drives the SSC co-processor -- but no HAL service existed at all:
#   /vendor/bin/hw/android.hardware.sensors@2.0-service.multihal   (absent)
#   service check android.hardware.sensors.ISensors/default        (not found)
#   lshal | grep sensors@                                          (no output)
# so SensorService had nothing to bind.
#
# proprietary-files.txt now packages the binary plus its rc file. The two HIDL
# interface libraries it links at runtime live in /system/lib64 on A16, which a
# vendor process cannot see (no VNDK), so select them here and let soong install
# vendor copies.
PRODUCT_PACKAGES += \
    android.hardware.sensors@2.0 \
    android.hardware.sensors@2.1 \
    android.hardware.sensors@2.0-ScopedWakelock

# v132bw31: the service binary itself (soong module, rc+fragment ship with it).
# The v127 vendor_parity restore mechanism was lost in the BK rollback; without
# a registered ISensors@2.0 the declared-but-absent pattern deadlocks
# SensorService's OnBootPhase on the main thread (185 s watchdog loop).
PRODUCT_PACKAGES += \
    android.hardware.sensors@2.0-service.multihal

# v132bw33: system-domain AIDL audio service (IConfig bridge for AudioService).
# v132bw41c: also the system-domain audio effect service (IFactory) - the vendor
# apex copy registers on vndbinder, audioserver never sees it, AudioPolicyService
# never registers -> listAudioPorts -32 -> bluetooth A2DP retry loop.
PRODUCT_PACKAGES += \
    android.hardware.audio.service-aidl.avium \
    android.hardware.audio.effect.service-aidl.avium \
    android.hardware.bluetooth.audio.vintf.xml

# v127: Bluetooth controller firmware. Same gap as the Wi-Fi firmware
# (see proprietary-files.txt): the BCM4375 hcd blobs were never packaged,
# so /vendor/firmware had no .hcd for the BT core to patch into the
# controller. bcm4361_bluetooth_init in dmesg confirms the BT core is
# present; without these the controller never reaches a usable state.
# NOTE: full paths are required here -- $(PROP) is only defined inside
# vendor_restore.mk, and fsgen rejects an unresolved variable as a path
# outside the source root.
BT_FW_DIR := vendor/samsung/sm8150-common/proprietary/firmware
PRODUCT_COPY_FILES += \
    $(BT_FW_DIR)/bcm4375B1_murata.hcd:$(TARGET_COPY_OUT_VENDOR)/firmware/bcm4375B1_murata.hcd \
    $(BT_FW_DIR)/bcm4375B1_semco.hcd:$(TARGET_COPY_OUT_VENDOR)/firmware/bcm4375B1_semco.hcd \
    $(BT_FW_DIR)/bcm4375B1_semco_sem.hcd:$(TARGET_COPY_OUT_VENDOR)/firmware/bcm4375B1_semco_sem.hcd \
    $(BT_FW_DIR)/bcm4375B0_murata.hcd:$(TARGET_COPY_OUT_VENDOR)/firmware/bcm4375B0_murata.hcd \
    $(BT_FW_DIR)/bcm4375B0_semco.hcd:$(TARGET_COPY_OUT_VENDOR)/firmware/bcm4375B0_semco.hcd

# v126: force the ISupplicant VINTF fragment to declare AIDL version 5.
#
# external/wpa_supplicant_8/wpa_supplicant/aidl/vendor/Android.bp declares a
# vintf_fragment from aidl/vendor/android.hardware.wifi.supplicant.xml, but
# soong rewrites the version to the highest *frozen* AIDL version. For
# android.hardware.wifi.supplicant that is 4
# (hardware/interfaces/wifi/supplicant/aidl/aidl_api/.../{1,2,3,4,current}),
# while the wpa_supplicant binary links
# android.hardware.wifi.supplicant-V5-ndk (the unfrozen "current" API).
# A v4 declaration makes the framework's ISupplicant lookup miss, so
# supplicant's addIface fails with
#   ServiceSpecificException: Conf file does not exist
# and WifiNative reports "Failed to start supplicant" -> ClientModeManager
# tears down the STA iface -> wifi never turns on.
# v127: no device-side fragment needed any more. The real fix is in
# hardware/interfaces/wifi/supplicant/aidl/Android.bp, where version 5 was
# added to versions_with_info so soong's generated vintf_fragment declares 5
# (matching android.hardware.wifi.supplicant-V5-ndk, which wpa_supplicant
# links). A device-side override fragment could not work: it installs to the
# same path as the generated one and soong rejects it with
#   packaging conflict at etc/vintf/manifest/android.hardware.wifi.supplicant.xml

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
# [v135] android.hardware.gatekeeper@1.0-service removed: it registered a
# second @1.0::IGatekeeper/default (its VINTF fragment collides with the
# stock backfill manifest entry) and the AIDL gatekeeper-service.nonsecure
# below is the service actually in use since v130 (bug#5). The passthrough
# -impl stays for the Samsung TEE gatekeeper libraries.
PRODUCT_PACKAGES += \
    android.hardware.gatekeeper@1.0-impl

# v130: AIDL 软件版 gatekeeper（bug#5）。
# A16 的 gatekeeperd 走 AIDL android.hardware.gatekeeper.IGatekeeper/default；
# Samsung 的 HIDL mdfpp 实现在 enroll 时于 libcrypto ASN1_item_ex_new 处
# SIGSEGV（ASN1_ITEM 数据布局跨版本断裂，无法 shim）。本模块同时提供
# ISharedSecret/gatekeeper。注意它是 nonsecure（口令处理不进 TEE），
# bring-up 可接受；后续若解出 mdfpp ABI 可回切。
# Avium beyond1q: the com.android.hardware.gatekeeper.nonsecure APEX is NOT
# installed. Its binary cannot load the Samsung MDFPP TEE gatekeeper (APEX
# linker namespace permits only /apex/<self>, /system, /system_ext, so
# /vendor/lib64/hw/gatekeeper.default.so is unreachable). The software fallback
# then mints non-TEE HATs and fingerprint enrollment always fails with
# "BAuth_Hat_OP fail rv : 28". avium.gatekeeper-service.vendor installs the same
# source to /vendor/bin/hw, where the vendor namespace can reach the patched TEE
# module, and provides the only IGatekeeper/default definition.
# PRODUCT_PACKAGES += com.android.hardware.gatekeeper.nonsecure
PRODUCT_PACKAGES += avium.gatekeeper-service.vendor

# v125: keymaster@4.0 must be the AOSP *software* service, not the Samsung
# TEE blob.
#
# The blob (vendor/samsung/.../vendor/bin/hw/android.hardware.keymaster@4.0-
# service, links libskeymaster4device) crashes on every start:
#   skeymaster4dev: Creating SKEYMASTER v4 DEVICE
#   keymaster_tee: [WRN]Open MDFPP keymaster version 4.3.11
#   -> SIGSEGV inside libcrypto ASN1_item_ex_new (ASN1 NULL deref at 0x1c)
# because it was built against the pre-3.0 BoringSSL ASN1 layout.
#
# That alone would be survivable, but keystore2 deadlocks on it:
#   system/security/keystore2/src/km_compat/km_compat.cpp:1510
#     sp<Keymaster> getDevice(...) {
#         static std::mutex mutex;
#         std::lock_guard lock(mutex);            // held for the whole call
#         if (!teeDevice) {
#             auto devices = initializeKeymasters();  // HIDL getService()
#
# initializeKeymasters() calls IKeymasterDevice::getService(), which retries
# forever while no one can register the instance. keystore2 therefore sits in
# futex_wait holding that static mutex, /data/misc/keystore stays empty, and
# the compat service it publishes answers nothing ("No data available").
#
# SystemServer then dies at boot with
#   java.lang.IllegalStateException: Could not connect to Keystore service
#     at LockSettingsService.migrateUserToSpWithBoundKeysLocked
# so the AOSP software keymaster (which always registers) is the way in.
# TEE-bound FBE keys cannot be unwrapped this way, but /data is unencrypted
# here, so that is acceptable for bring-up.
#
# The service binary name collides with the Samsung blob. The blob is still
# packaged by the generated vendor.mk, so the AOSP build lands under a
# different stem (see Android.bp) and romfix.rc points the rc at it.
PRODUCT_PACKAGES += \
    android.hardware.keymaster@4.0-service_aosp

# Keystore2 (A16) only talks KeyMint AIDL. The system-domain bridge
# android.hardware.security.keymint-service.avium (added below, v132bs3)
# registers IKeyMintDevice/ISecureClock/ISharedSecret on /dev/binder and is the
# one keystore2 must use.
#
# Do NOT ship android.hardware.security.keymint-service. The AIDL declarations
# now live in DEVICE_MANIFEST_FILE (manifest_stock_backfill.xml), so the vendor
# module is redundant. Its vintf fragments (keymint/sharedsecret/secureclock
# -service.xml) would conflict with the merged manifest.xml at runtime
# ("Conflicting FqInstance ISharedSecret/default") and make VINTF parsing fail,
# which aborts the avium keymint service and crashes keystore2.
#PRODUCT_PACKAGES += \
#    android.hardware.security.keymint-service

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
# v129: 32-bit libprotobuf for the Qualcomm camera HAL.
#
# /vendor/lib/hw/camera.qcom.so (32-bit, Qualcomm CAMX) has
#   DT_NEEDED  libprotobuf-cpp-full-3.9.1.so
# but the device only shipped the 64-bit copy. The 32-bit HAL therefore failed
# to dlopen:
#
#   E vndksupport: Could not load /vendor/lib/hw/camera.qcom.so from default
#   namespace: dlopen failed: library "libprotobuf-cpp-full-3.9.1.so" not found
#
# That cascaded into the camera provider dying on every boot:
#
#   E Unihal : MultiCameraManager.cpp:53: Vendor HAL module not loaded(-22)
#   F DEBUG  : #00 unihal::MultiCameraManager::GetVendorHalModule()+0
#              (null deref -- unihal never checks the hw_get_module result)
#
# The 32-bit blob already exists in the tree at
# hardware/lineage/compat/libprotobuf/arm/ and is exposed by the
# libprotobuf-cpp-full-3.9.1-vendorcompat module; it just was never installed.
# Installing it makes cameraserver enumerate all four sensors:
#   CameraProviderManager: Camera provider legacy/0 ready with 4 camera devices
PRODUCT_PACKAGES += \
    libprotobuf-cpp-full-3.9.1-vendorcompat

PRODUCT_PACKAGES += \
    android.hardware.power-service.avium

# Avium v132al: LightsService blocks the system_server boot thread on
# waitForDeclaredService(ILights/default) against the SYSTEM servicemanager;
# the vendor lineage light registers on vndSM (no bridge in this bp4a).
PRODUCT_PACKAGES += \
    android.hardware.light-service.lineage.avium

# Avium v132bw: system-domain health so BatteryService's waitForService(IHealth)
# resolves (same bridge gap; see hardware/interfaces/health/aidl/default).
PRODUCT_PACKAGES += \
    android.hardware.health-service.avium \
    android.hardware.health-service.avium.xml

# Avium v132bs3: system-domain keymint (+sharedsecret+secureclock) so
# LockSettingsService's waitForDeclaredService resolves. See the .avium
# module in hardware/interfaces/security/keymint/aidl/default/Android.bp.
PRODUCT_PACKAGES += \
    android.hardware.security.keymint-service.avium

PRODUCT_PACKAGES += \
    android.hardware.camera.common@1.0 \
    android.hardware.drm@1.0 \
    android.hardware.drm@1.3 \
    libcbs_shim \
    android.hardware.gnss@1.0 \
    android.hardware.health@2.1 \
    android.hardware.neuralnetworks@1.0 \
    android.hardware.usb@1.0 \
    android.hidl.allocator@1.0 \
    libcamera_metadata \
    libprocessgroup

# v125: the rest of the /system/lib64 interface libraries that Samsung's
# vendor HAL binaries (and their impl .so files) dlopen or link against.
# A16 has no VNDK, so vendor processes only see /odm/lib*, /vendor/lib* and
# /vendor/lib*/{hw,egl}; anything that lives only in /system/lib64 is
# invisible. Each of these was found by walking the failing dlopen chain:
#
#   gnss@2.1-service-qti  -> android.hardware.gnss.visibility_control@1.0,
#                            android.hardware.gnss.measurement_corrections@1.1
#   gnss@2.1-impl-qti     -> android.hardware.power@1.2 -> @1.0 -> @1.1
#                            (the whole HIDL power chain, one at a time)
#   wifi@1.0-service      -> android.hardware.security.keymint-V1-ndk
#                            (via android.system.keystore2-V1-ndk)
#   samsung.software.media.c2@1.0-service -> libcodec2_hidl@1.1
#   media.converter@1.0-service / mppserver -> android.hardware.common-V1-ndk_platform
#   dumpstate@1.1-service-lazy -> android.hardware.dumpstate@1.0/@1.1, libdumpstateutil
#   nxp.android.hardware.nfc@1.1-service -> android.hardware.nfc@1.0/@1.1/@1.2
#                            (the blob NEEDs @1.2 too; without it the HAL dies
#                             with: library "android.hardware.nfc@1.2.so" not
#                             found, and nothing ever registers, so
#                             com.android.nfc requests
#                             android.hardware.nfc@1.2::INfc/default forever)
#   netmgrd               -> libnetd_client, android.system.net.netd@1.0
#   thermal (samsung)     -> android.frameworks.cameraservice.{common,device}@2.0
#                            (the .service@2.0/2.1 blobs are prebuilts, see
#                             vendor_restore.mk)
#
# All of these are hidl_interface / cc_library_shared modules that are
# vendor_available, so listing them here installs the vendor variant into
# /vendor/lib64 (and /vendor/lib for the 32-bit build).
PRODUCT_PACKAGES += \
    android.frameworks.cameraservice.common@2.0 \
    android.frameworks.cameraservice.device@2.0 \
    android.hardware.dumpstate@1.0 \
    android.hardware.dumpstate@1.1 \
    android.hardware.gnss.measurement_corrections@1.1 \
    android.hardware.gnss.visibility_control@1.0 \
    android.hardware.nfc@1.0 \
    android.hardware.nfc@1.1 \
    android.hardware.nfc@1.2 \
    android.hardware.power@1.0 \
    android.hardware.power@1.1 \
    android.hardware.power@1.2 \
    android.hardware.power@1.3 \
    android.hardware.security.keymint-V1-ndk \
    android.system.net.netd@1.0 \
    libdumpstateutil \
    libnetd_client

# v125: the NDK backend of android.hardware.common (hardware/interfaces/
# common/aidl/Android.bp has backend.ndk enabled) produces versioned module
# names. Samsung's vendor.samsung.hardware.media.converter-V1-ndk_platform.so
# and libmpp.so both DT_NEEDED
#   android.hardware.common-V1-ndk_platform.so
# but soong only defines
#   android.hardware.common-V1-ndk          (V1 has min_sdk_version set)
#   android.hardware.common-V2-ndk
#   android.hardware.common-V2-ndk_platform
# so the exact name Samsung wants is not a module in this tree, and listing it
# in PRODUCT_PACKAGES fails kati with
#   "includes non-existent modules in PRODUCT_PACKAGES".
#
# That only affects mppserver and vendor.samsung.hardware.media.converter@1.0
# (both non-essential). Left out for now so the main build passes; supplying
# it would mean building android.hardware.common-V1-ndk and installing a
# prebuilt under the _platform stem.

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

# Built-in root (v122). system/extras/su builds su with install_in_xbin, so it
# lands at /system/xbin/su, which system/sepolicy/private/file_contexts:324
# already labels su_exec. system/sepolicy/private/su.te provides
# "permissive su" and domain_auto_trans(shell, su_exec, su), so once exec'd
# the process runs unrestricted. The uid gate in su.cpp was lifted so any
# process can use it, not just root/shell.
PRODUCT_PACKAGES += \
    su

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
    $(COMMON_PATH)/usbdbg.sh:$(TARGET_COPY_OUT_VENDOR)/bin/usbdbg.sh \
    $(COMMON_PATH)/storage_fix.sh:$(TARGET_COPY_OUT_VENDOR)/bin/storage_fix.sh

# Restores the vendor files that proprietary-files.txt lists but the stale
# generated makefiles (vendor/samsung/sm8150-common/{Android.bp,vendor.mk},
# last regenerated 2026-10-27) never covered. This is what was keeping
# init.qcom.usb.rc -- and therefore adb -- out of the vendor image.
$(call inherit-product, $(COMMON_PATH)/vendor_restore.mk)

# NOTE: /vendor/{firmware_mnt,firmware-modem,dsp} mount points used to be added
# by fix_vendor_mountpoints.sh (post-build debugfs). They are now declared in
# vendor_native_fixes.mk with .keep placeholders, so a plain vendorimage build
# creates them; the mounted filesystem hides the placeholder at runtime.
$(call inherit-product, $(COMMON_PATH)/vendor_native_fixes.mk)

# Pre-authorised adb key so `adb` connects without the on-device confirmation
# dialog (the device is headless during bring-up). Installed to /system/etc,
# which survives a /data wipe.
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/adb/adb_keys:$(TARGET_COPY_OUT_SYSTEM)/etc/adb_keys


# v123: audio HAL. This build is 64-bit only (/system/lib is empty, so
# ro.product.cpu.abilist32 is empty), but AOSP's
# android.hardware.audio.service defaults to compile_multilib: "prefer32",
# so nothing was produced at all and audioserver crash-looped. That kept
# AudioService.onAudioServerDied firing every 0.5 s inside system_server,
# which blocked boot_completed forever.
#
# Setting the android_hardware_audio run_64bit soong config variable makes
# the module build as 64-bit.
$(call soong_config_set_bool,android_hardware_audio,run_64bit,true)

# v128: audio policy + engine configuration.
#
# The A16 audio HAL validates every device port in the policy and refuses to
# start on a mismatch, and it also needs the engine configuration for the volume
# tables. Both are shipped from the device tree rather than the vendor blob
# because the blob's copies are Android-11 schema and are rejected
# (convertCollectionToAidl BAD_VALUE).
#
# What each file is for:
#   audio_policy_configuration.xml          7.0 schema, incremental port set
#                                           (speaker + built-in mics only);
#                                           the full upstream port list aborts
#                                           HAL startup on Earpiece/Telephony Tx
#   audio_policy_engine_configuration.xml   pulls in the volume tables; the
#                                           framework otherwise reports
#                                           Max: 0 for the media streams
#   audio_policy_engine_stream_volumes.xml  upstream copy plus the missing
#                                           "call_assistant" volume group that
#                                           product_strategies references
#   audio_policy_engine_product_strategies.xml
#                                           upstream copy minus the strategies
#                                           whose attribute groups abort the HAL
#                                           in convertAttributesGroupToAidl
#   audio_policy_engine_default_stream_volumes.xml
#                                           default curves referenced by the
#                                           stream volume table
# v130: real audio output through the vendor legacy HAL.
#
# The A16 framework only speaks the AIDL audio HAL, while this device's audio
# routing (mixer_paths_tavil.xml, ACDB calibration, DSP front ends) lives in
# Samsung's legacy HAL: /vendor/lib/hw/audio.primary.msmnile.so (ELF32 ARM).
# AOSP's "example" AIDL HAL drives tinyalsa directly, so it opens pcmC0D0p and
# accepts frames but never starts the stream -- audio is silent.
#
# android.hardware.audio.service-aidl (hardware/interfaces/audio/aidl) is now
# built 32-bit and its ModuleLegacy/StreamLegacy backend opens the vendor HAL
# through hw_get_module_by_class("audio", "primary") and forwards
# transfer() to the legacy stream's write()/read(). Non-PCM (offload) and
# mmap streams still use the AOSP ALSA backend as a fallback.
PRODUCT_PACKAGES += android.hardware.audio.service-aidl

# v136: runtime dependencies of prebuilt vendor blobs.
#   libaudioroute: audio.primary.msmnile.so (ELF32) NEEDs it. The AOSP module is
#       made system-only (vendor_available: false) so it does not create a
#       /vendor/lib install rule; the 32-bit build is shipped as a tree blob by
#       vendor_native_prebuilts.mk instead.
#   libstagefright_bufferqueue_helper + android.hidl.token@1.0*: the C2 service
#       needs the vendor variants. They are AOSP-built and their vendor variant
#       pulls a large dependency closure (libui/libEGL/...) that would collide
#       with the stock vendor blobs; inject_vendor_hidl_libs.sh fills these two
#       paths after image assembly until the vendor blob tree is regenerated.

AUDIO_CFG := device/samsung/sm8150-common
PRODUCT_COPY_FILES += \
    $(AUDIO_CFG)/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/surround_sound_configuration_5_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/surround_sound_configuration_5_0.xml \
    $(AUDIO_CFG)/audio_engine/audio_policy_engine_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_engine_configuration.xml \
    $(AUDIO_CFG)/audio_engine/audio_policy_engine_stream_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_engine_stream_volumes.xml \
    $(AUDIO_CFG)/audio_engine/audio_policy_engine_product_strategies.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_engine_product_strategies.xml \
    $(AUDIO_CFG)/audio_engine/audio_policy_engine_default_stream_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_engine_default_stream_volumes.xml

# v129: Dolby Audio Processing (DAP) effect configuration.
#
# The Samsung blobs ship everything DAP needs -- libswdap.so (the effect
# implementation), dax-default.xml (the DAX3 tuning set), libeffectproxy.so
# (the soft/hard switcher), libaudioeffectoffload.so (the offload path) -- and
# audio_effects_sec.xml already declares both the "dap" library and the
# "dap_proxy" effect. The effect HAL itself (android.hardware.audio.effect
# .IFactory/default) registers fine.
#
# It never loaded because of two things:
#
#  1. Name. Android 16's effect HAL reads exactly one filename
#     (hardware/interfaces/audio/aidl/default/EffectMain.cpp):
#         static const char* kDefaultConfigName = "audio_effects_config.xml";
#     The device has /vendor/etc/audio_effects_config.xml, but that one is the
#     AOSP default (no libswdap). The Samsung config is installed under the
#     name audio_effects_sec.xml, which nothing reads.
#
#  2. A private stream type. The Samsung config applies AEC to
#     <stream type="sec_voice_communication">, which
#     EffectConfig::stringToProcessingType does not know. An unknown type
#     makes registerFailure() fire and the entire config load abort.
#
# device/samsung/sm8150-common/audio_effects/audio_effects_config.xml is the
# Samsung config with that block removed (AEC still applies to the standard
# voice_communication stream), installed under the name the HAL reads.
PRODUCT_COPY_FILES += \
    $(AUDIO_CFG)/audio_effects/audio_effects_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_effects_config.xml

# v128: AIDL radio compatibility service.
#
# Android 16's telephony stack speaks the AIDL radio HAL:
#   frameworks/opt/telephony/.../ModemIndication.java imports
#     android.hardware.radio.modem.IRadioModemIndication
# but Samsung's rild only implements HIDL (radio@1.0..1.1, radio.config@1.0..1.1).
# Without a bridge every radio registration request fails with
#   Could not find android.hardware.radio.modem.IRadioModem/slot1
#   in the VINTF manifest. No alternative instances declared in VINTF.
# and Telephony never sees a SIM (gsm.sim.state=ABSENT, ril.hasisim=0).
#
# hardware/interfaces/radio/aidl/compat/service is AOSP's own HIDL->AIDL
# adapter for exactly this case. It links radio@1.0..1.6 and radio.config@1.0..1.3
# and republishes them as the AIDL interfaces the framework expects.
# v132bw41c: now actually selected - with the modem partition mounted the
# baseband boots and rild registers the HIDL IRadio, which this bridge
# republishes as the AIDL IRadio{,Modem,SIM,Data,Network,Messaging,...}/slot1-2
# the A16 telephony stack requires (VoLTE prerequisite).
#
# Use the .avium instance, not the upstream module name. Two reasons:
#   1. The upstream cc_binary ships radio-compat.xml, which declares
#      IRadioConfig/default - an instance our device manifest
#      (manifest_stock_backfill.xml) already declares. Two manifests claiming
#      the same FqInstance aborts the entire VINTF merge:
#        VINTF parse error: ... "android.hardware.radio.config" has a conflict:
#        Conflicting FqInstance: IRadioConfig/default (@1)
#        NULL VINTF MANIFEST!: device
#      and with no usable device manifest nothing resolves: surfaceflinger
#      restart-loops on EGL_BAD_ALLOC (stuck on the boot logo), adsp services
#      fail with "Transport endpoint is not connected", camera loops.
#   2. The upstream service.cpp asks for V1_5::IRadio::getService(), but
#      Samsung's rild only registers up to @1.4, so it returns null and the
#      upstream CHECK() aborts the process (4 exits -> download mode).
# The .avium module carries the V1_4 binding, the null-safe publication and a
# fragment that declares nothing (the device manifest has the full set).
# 2026-11-20: re-enabled after the boot-blocker was found to be unrelated.
# The images that failed to boot were built with a bare
#   m systemimage vendorimage
# which skips build_detached.sh, and therefore skips
# inject_vendor_hidl_libs.sh. That script writes /vendor/etc/linker.config.pb,
# the vendor sepolicy/file_contexts patches, brgup.rc, the allocator/composer
# services and the vendor build.prop patch. Without them the boot died with
#   init: Command 'mount_all /vendor/etc/fstab.qcom --late' ... failed
#   init: Reboot already performed in last 24hrs because of crash.
# (stuck at the boot logo, then download mode).
# Verified 2026-11-20: the same tree built through build_detached.sh boots to
# sys.boot_completed=1 with every core service running, so the bridge itself is
# not implicated. ALWAYS build flashable images with build_detached.sh.
PRODUCT_PACKAGES += \
    android.hardware.radio-service.compat.avium

# Avium v132bt: system_server heap 512m -> 768m. A16 server footprint fills the
# 512m ceiling within ~3 min of boot_completed on this build (Dalvik Heap grows
# ~3 MB/s, ActivityManager thread OOM-kills the server every cycle, so SystemUI
# never survives long enough to draw the launcher). Raised ceiling buys the boot
# phase room; the leak source is tracked separately.
PRODUCT_PROPERTY_OVERRIDES += \
    dalvik.vm.systemserverheapsize=768m

# v132fix: a launchable camera app. The board's camera HAL enumerates 4 devices
# (verified: ADD device 0-3 after boot) but the image shipped no default camera
# app (only the GCam fishfood stub, which has no LAUNCHER activity), so tapping
# the camera icon opened nothing. Camera2 is in the tree (packages/apps/Camera2).
PRODUCT_PACKAGES += \
    Camera2

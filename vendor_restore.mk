# ============================================================
# v114: package the vendor files that proprietary-files.txt listed but
#       the generated makefiles (stale since 2026-10-27) never covered.
# ============================================================
#
# Background
# ----------
# device/samsung/sm8150-common/proprietary-files.txt is the source of truth
# and is consumed by setup-makefiles.sh, which regenerates
# vendor/samsung/sm8150-common/{Android.bp,sm8150-common-vendor.mk}. That
# script needs vendor/lineage/build/tools/extract_utils.sh, which is not
# present in this tree, so the generated files can never be refreshed here.
# The list was last edited 2026-10-30 but the generated files are from
# 2026-10-27, so every entry added after that date was silently dropped.
#
# This file restores the ones that actually matter at runtime. Non-ELF
# payloads (rc files, xml, firmware blobs, scripts) go through
# PRODUCT_COPY_FILES; ELF payloads must be cc_prebuilt_* modules in
# Android.bp because kati rejects ELF files in PRODUCT_COPY_FILES.

PROP := vendor/samsung/sm8150-common/proprietary

# ---- init rc files that init.rc / init.qcom.rc import or auto-load ----
# init.qcom.rc:28 "import /vendor/etc/init/hw/init.qcom.usb.rc" fails
# outright without this file, which is the root cause of adb never coming
# up: no code ever created functions/ffs.adb, so every composition died
# with "udc a600000.dwc3: failed to start g1: -19".
PRODUCT_COPY_FILES += \
    $(PROP)/vendor/etc/init/hw/init.qcom.usb.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.qcom.usb.rc

# ---- GPU firmware ----
# kgsl requests these at boot; without them a640_zap/a640_gmu never
# finish bringing the GPU out of reset.
PRODUCT_COPY_FILES += \
    $(PROP)/firmware/a630_sqe.fw:$(TARGET_COPY_OUT_VENDOR)/firmware/a630_sqe.fw \
    $(PROP)/firmware/a640_gmu.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/a640_gmu.bin \
    $(PROP)/firmware/a630_gmu.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/a630_gmu.bin \
    $(PROP)/firmware/a618_gmu.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/a618_gmu.bin \
    $(PROP)/firmware/a612_rgmu.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/a612_rgmu.bin

# ---- codec / media config ----
PRODUCT_COPY_FILES += \
    $(PROP)/vendor/etc/media_codecs.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs.xml \
    $(PROP)/vendor/etc/seccomp_policy/mediacodec.policy:$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy/mediacodec.policy

# ---- service rc files ----
# Neither the allocator-service rc nor the memtrack rc is copied here: their
# source modules (hardware/qcom-caf/sm8150/display/gralloc and
# hardware/interfaces/memtrack/1.0/default) declare them through init_rc,
# so a second copy produces "overriding commands for target". Both were
# missing from the flashed image only because those modules were not
# selected; they are now, via the product configuration.

# ---- install-recovery.sh ----
# Already packaged: vendor/samsung/sm8150-common builds an install-recovery
# module from this same blob (see installs-lineage_beyond1q.mk), so copying
# it again gives "overriding commands for target".

# ---- memtrack HAL ----
# hardware/interfaces/memtrack/1.0 builds these from source with
# proprietary: true. They appear in installs-lineage_beyond1q.mk as
# dependencies but were never in PRODUCT_PACKAGES, so nothing was installed
# and system_server's startMemtrackProxyService blocked forever.
PRODUCT_PACKAGES += \
    android.hardware.memtrack@1.0-service

# ---- QTI display stack ----
# Everything in this stack except libsdedrm is already built from source:
# hardware/qcom-caf/sm8150/display/gralloc provides
# vendor.qti.hardware.display.allocator-service and both
# android.hardware.graphics.mapper@{3,4}.0-impl-qti-display modules, and
# vendor/qcom/opensource/interfaces provides the allocator/mapper HIDL
# interface libs. Declaring prebuilts for those only produced
# "overriding commands for target" errors, so they are not listed here.
# libsdedrm has no source module anywhere in the tree.
#
# The allocator service is deliberately NOT selected here. Its only
# definition in the build graph is
# hardware/qcom-caf/sm8150/display/gralloc/vendor.qti.hardware.display.
# allocator-service, and that module does not compile against A16 bionic
# (libgralloccore/libgrallocutils fail with "redefinition of 'sched_param'").
# Selecting either that module or a same-stem prebuilt puts two install
# rules on /vendor/bin/hw/vendor.qti.hardware.display.allocator-service and
# kati refuses with "overriding commands for target".
#
# It keeps being supplied the way it always has been: by
# device/samsung/sm8150-common/fix_vendor_mountpoints.sh, which writes the
# stock blob into the image and labels it
# hal_graphics_allocator_default_exec.
PRODUCT_PACKAGES += \
    libsdedrm_stock_prebuilt

# ---- secril_config_svc ----
# init.vendor.rilcommon.rc exec_starts it as sim_config (on fs) and
# network_config (on post-fs-data). hardware/samsung/ril/secril_config_svc
# already builds it from source, it just was not selected.
PRODUCT_PACKAGES += \
    secril_config_svc

# ---- v125: vendor blobs that exist only in the vendor tree ----
# Only libhyper.so needs copying. Everything else in this group is already
# installed by soong once the interface modules are in PRODUCT_PACKAGES
# (see common.mk): adding common.mk entries for
# android.frameworks.cameraservice.{common,device}@2.0 pulls in
# .service@2.0/.service@2.1, and android.hardware.nfc@1.0/@1.1 pulls in
# nfc_nci_nxp.so and libcodec2_hidl@1.1.so transitively. Copying them again
# makes kati fail with
#   overriding commands for target
#   .../vendor/lib64/android.frameworks.cameraservice.service@2.0.so
# so they are deliberately absent from this list.
#
# libhyper.so (vendor.samsung.hardware.hyper-service) has no module in the
# build graph at all.
PRODUCT_COPY_FILES += \
    $(PROP)/vendor/lib64/libhyper.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libhyper.so

# ---- v125: health@2.1 impl under the name the service looks for ----
# android.hardware.health@2.1-service-samsung does
#   IHealth_2_0::getService("default", /*getStub=*/true)
# which resolves the passthrough library by the *interface* name, i.e.
# android.hardware.health@2.1-impl.so (and the 2.0 form). Samsung ships the
# implementation only as android.hardware.health@2.0-impl-2.1-samsung.so, so
# every start aborts with
#   Check failed: passthrough != nullptr
#   Cannot find passthrough implementation of health 2.1-samsung HAL
# and BatteryService.onStart blocks on the system_server main thread.
# Symlinks are created by romfix.rc (init cannot copy symlinks from
# PRODUCT_COPY_FILES), see the "health impl" block there.

# v127: the old libbase ABI (WriteStringToFd(const string&, borrowed_fd),
# Basename/Dirname(string), StartsWith(string, const char*), Trim(string)) is
# now compiled into libbase itself, in system/libbase/Android.bp. It cannot be
# a separate vendor library: vndksupport loads vendor HALs in the "(default)"
# linker namespace, which only searches /system/lib64, so an LD_PRELOAD shim
# from /vendor/lib64 is never considered. Nothing to select here.
#
# Previously also carried libcgroup_shim for the stock composer; that module
# is still declared in Android.bp but is not installed either, see above.
PRODUCT_PACKAGES += \
    libcgroup_shim

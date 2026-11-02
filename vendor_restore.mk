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

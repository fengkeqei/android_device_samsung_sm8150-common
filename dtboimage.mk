# Avium beyond1q: custom dtboimage makefile.
#
# Why this exists
# ---------------
# The stock Samsung DTBO carries an fstab overlay that mounts the OMC partition
# (sda27) over /product:
#
#   product { dev = "/dev/block/platform/soc/1d84000.ufshc/by-name/product";
#             fsmgr_flags = "wait,verify,avb"; }
#
# On Android 16 this tree merges /product into /system/product, so the OMC
# mount covers the merged content. init then cannot read
# /system/product/etc/selinux/product_sepolicy_and_mapping.sha256, decides the
# plat/product/system_ext stamps "differ", recompiles the policy, fails on the
# missing /system/etc/selinux/mapping/202504.cil and lands in
# InitFatalReboot -> kernel panic -> download mode. That was the infinite
# reboot loop after every stock flash (see BUILD_NOTES.md 2026-10-28 03:15).
#
# The prebuilt below is the same DTBO with that one FDT node removed
# (decompiled, node deleted, recompiled, AVB hash footer re-added). Kernel DTBO
# generation is bypassed on purpose: the device tree shipped in the kernel
# source is the A12 template that still carries the node.
#
# BOARD_CUSTOM_DTBOIMG_MK replaces the default generation rules, so this is the
# only rule producing $(BOARD_PREBUILT_DTBOIMAGE). The target is the usual
# intermediates path (never the source tree: Kati rejects writing there).

AVIUM_DTBO_PREBUILT := $(COMMON_PATH)/prebuilt/dtbo.img

$(BOARD_PREBUILT_DTBOIMAGE): $(AVIUM_DTBO_PREBUILT)
	@echo "Installing prebuilt dtbo.img (product mount node removed)"
	$(hide) mkdir -p $(dir $@)
	$(hide) cp $< $@
	$(hide) chmod +w $@

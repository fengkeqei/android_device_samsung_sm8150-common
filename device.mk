# Licensed under the Apache License, Version 2.0

DEVICE_PACKAGE_OVERLAYS := $(LOCAL_DIR)/overlay-lineage

PRODUCT_COPY_FILES += \
    $(call all-copyfiles-in-dir, $(LOCAL_DIR)/overlay/,$(TARGET_COPY_OUT_SYSTEM)/vendor/overlay/)

# fstab 挂载点必须存在于 vendor 镜像里，否则 first-stage/init 挂载 vfat 固件分区会失败：
#   __mount(apnhlos, /vendor/firmware_mnt(missing)) = -1: No such file or directory
# 结果就是 TEE trustlet（vaultkee/km4）加载失败、modem 固件缺失。
# 空目录不会被 git 保留，这里用占位文件强制生成。
# NOTE: 新 soong 的 fsgen 会把这些 .keep 复制当成 mountpoint，报
#   "Path is outside directory: ../firmware-modem"，故暂时注释掉（bring-up 阶段
#   modem/apnhlos 分区不存在，fstab 已去掉对应挂载，这些目录也不再需要）。
#PRODUCT_COPY_FILES += \
#    $(LOCAL_DIR)/configs/mountpoints/.keep:$(TARGET_COPY_OUT_VENDOR)/firmware_mnt/.keep \
#    $(LOCAL_DIR)/configs/mountpoints/.keep:$(TARGET_COPY_OUT_VENDOR)/firmware-modem/.keep \
#    $(LOCAL_DIR)/configs/mountpoints/.keep:$(TARGET_COPY_OUT_VENDOR)/bt_firmware/.keep \
#    $(LOCAL_DIR)/configs/mountpoints/.keep:$(TARGET_COPY_OUT_VENDOR)/firmware/.keep


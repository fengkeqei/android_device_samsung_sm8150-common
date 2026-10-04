# Licensed under the Apache License, Version 2.0

DEVICE_PACKAGE_OVERLAYS := $(LOCAL_DIR)/overlay-lineage

PRODUCT_COPY_FILES += \
    $(call all-copyfiles-in-dir, $(LOCAL_DIR)/overlay/,$(TARGET_COPY_OUT_SYSTEM)/vendor/overlay/)

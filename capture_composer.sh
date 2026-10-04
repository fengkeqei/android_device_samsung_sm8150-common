#!/system/bin/sh
# Capture the hwcomposer candidates' output for diagnosis from recovery.
{
    echo "=== composer@2.1-service ==="
    /vendor/bin/hw/android.hardware.graphics.composer@2.1-service
    echo "exit=$?"
    echo "=== composer@2.4-service ==="
    /vendor/bin/hw/android.hardware.graphics.composer@2.4-service
    echo "exit=$?"
} > /data/vendor/composer_capture.log 2>&1

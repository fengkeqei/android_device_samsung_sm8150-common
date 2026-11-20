#!/system/bin/sh
# [bring-up] widevine service launcher.
#
# Samsung's libwvhidl.so (Android 11 era) references CBS_init(), which
# BoringSSL turned into a static inline and therefore never exports. The
# platform's libcrypto.so carries every other CBS_* symbol but not CBS_init,
# so the service dies at load time:
#
#   CANNOT LINK EXECUTABLE ".../android.hardware.drm@1.3-service.widevine":
#   cannot locate symbol "CBS_init" referenced by "/vendor/lib/libwvhidl.so"
#
# libcbs_shim.so supplies the missing out-of-line copy. init drops LD_PRELOAD
# from service environments (it only honours an explicit setenv, which the
# linker still refuses for the vendor namespace), so we export it here and
# exec the real binary -- that keeps the preload inside the target process
# instead of leaking into shell helpers.

export LD_PRELOAD=/vendor/lib/libcbs_shim.so
exec /vendor/bin/hw/android.hardware.drm@1.3-service.widevine

// [bring-up] libcbs_shim.so
//
// Samsung's libwvhidl.so (Android 11 era) was built against OpenSSL, where
// CBS_init() is an exported function. BoringSSL (which Android ships since
// Android 10) defines it as `static inline` in bytestring.h, so it is never
// emitted into libcrypto.so. Result at runtime:
//
//   CANNOT LINK EXECUTABLE ".../android.hardware.drm@1.3-service.widevine":
//   cannot locate symbol "CBS_init" referenced by "/vendor/lib/libwvhidl.so"
//
// CBS_init only initialises a two-field struct, so a tiny out-of-line copy is
// enough to satisfy the dynamic linker. Everything else libwvhidl needs
// (EVP_*, SHA256, ...) is already exported by the platform's libcrypto.so.

#include <stddef.h>
#include <stdint.h>

// Must match struct cbs_st in external/boringssl/src/include/openssl/bytestring.h
// (const uint8_t *data; size_t len;) for the ABI the blob was compiled against.
struct cbs_st_compat {
  const uint8_t *data;
  size_t len;
};

extern "C" void CBS_init(struct cbs_st_compat *cbs, const uint8_t *data, size_t len) {
  cbs->data = data;
  cbs->len = len;
}

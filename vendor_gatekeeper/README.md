# vendor_gatekeeper — Samsung MDFPP TEE gatekeeper (bring-up replacement)

## Why

LineageOS ships the AOSP **software** gatekeeper
(`hardware/libhardware/modules/gatekeeper/gatekeeper.cpp`). That module is a stub:
`soft_verify()` compares the password HMAC and returns 0/1, but it **never fills
`auth_token`** (the first line is `(void)auth_token;`). It therefore never mints a
`hw_auth_token_t`.

On this device `gatekeeperd` is the only producer of device-credential auth tokens:
it takes the HAL payload and calls `IKeystoreAuthorization.addAuthToken()`
(`system/core/gatekeeperd/gatekeeperd.cpp:402`). With no token, keystore2 rejects any
use of the SID-bound Synthetic-Password protector key:

```
keystore2: enforcements.rs:586: No suitable auth token for sids [...] type Some(3) received in last 15s found.
keystore2: Error::Km(r#KEY_USER_NOT_AUTHENTICATED)
SyntheticPasswordCrypto: Failed to decrypt blob  (UserNotAuthenticatedException)
→ LockSettingsService.checkCredential throws → SystemUI crashes → lock screen never unlocks
```

Setting a PIN *appears* to work because `SyntheticPasswordCrypto.createBlob()` encrypts
the SP blob with the plain `KeyGenerator` software key; only the **unlock** path reads
the key back out of keystore (where it is auth-bound) and needs the HAT.

## What

Samsung's stock gatekeeper HAL (`gatekeeper.mdfpp.so`) talks to the TEE gatekeeper TA
over `/dev/qseecom` and mints real HATs. It could not load on this port because it was
built against an **OpenSSL 1.1** libcrypto (`sk_delete`, `ASN1_item_d2i/i2d/new/free`,
`ASN1_INTEGER_*`, `ASN1_OCTET_STRING_*`, `EVP_cleanup`, … — 21 symbols) while the vendor
partition now ships BoringSSL.

Fix: redirect the module's `DT_NEEDED` to a **private** copy of the stock OpenSSL
libcrypto, so it does not collide with the BoringSSL `libcrypto.so` used by everything
else.

## Files (stored pre-patched)

| File | Installed to | Notes |
|------|--------------|-------|
| `gatekeeper.default.so` | `/vendor/lib64/hw/gatekeeper.default.so` | stock `gatekeeper.mdfpp.so` with `DT_NEEDED` `libcrypto.so` → `libcrypto_gk` (same-length, in-place `.dynstr` edit; SONAME left as `gatekeeper.mdfpp.so`) |
| `libcrypto_gk` | `/vendor/lib64/libcrypto_gk` | stock system `libcrypto.so` (OpenSSL-ish) with `DT_SONAME` `libcrypto.so` → `libcrypto_gk` (needs no extension; the linker matches the NEEDED string verbatim) |
| `android.hardware.gatekeeper@1.0-service.rc` | `/vendor/etc/init/android.hardware.gatekeeper@1.0-service.rc` | adds `drmrpc` to `group` (**required**: `/dev/qseecom` is `system:drmrpc` = uid 1000 / gid **1026**) + `on post-fs-data mkdir /data/vendor/gatekeeper` |

The patch is a byte-for-byte, same-length string swap inside `.dynstr`, so no
`patchelf` is needed and no ELF offsets shift.

## How it is applied

`device/samsung/sm8150-common/fix_vendor_mountpoints.sh` injects the three files into
`vendor.img` with `debugfs` and the correct SELinux labels (`vendor_file` for the two
libs, `vendor_configs_file` for the rc). The AOSP rc source is also patched so a plain
`mka vendorimage` already carries the `drmrpc` group.

## Verified

```
locksettings verify --old 0000  → Old password '0000' didn't match   (RC=255)
locksettings verify --old 1234  → Lock credential verified successfully (RC=0)
```
Gatekeeper service process maps `/vendor/lib64/hw/gatekeeper.default.so` +
`/vendor/lib64/libcrypto_gk` + `/vendor/lib64/libQSEEComAPI.so`, holds `/dev/qseecom`
open, and runs with `Groups: 1026`.

> Note: switching gatekeeper implementations invalidates existing password handles,
> so a credential reset (and thus loss of CE-encrypted data) is required once.

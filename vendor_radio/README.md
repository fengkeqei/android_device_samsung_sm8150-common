# vendor_radio — Samsung stock rild + patched libsec-ril

Materials injected into `/vendor` by `../fix_vendor_mountpoints.sh` so the modem
survives a vendor rebuild.

## Why

The device tree builds the AOSP-source `rild` (Round 43), whose `libril`
registers HIDL `IRadio` only up to **1.1**. Android 15 telephony (LineageOS 22.2)
looks for `IRadio` up to **1.4** plus the AIDL radio HALs
(`android.hardware.radio.{modem,sim,...}`). With the source rild:

- `com.android.phone` `ANR … failed to complete startup` every ~7 s (restart loop)
- `servicemanager: Could not find android.hardware.radio.modem.IRadioModem/slot1 …`
- no SIM / no IMEI / dead modem

Samsung's **stock** rild registers `IRadio 1.0/1.1/1.2/1.3/1.4` × slot1/slot2 via
`libril_sem.so`. It reads `vendor.sec.rild.libpath` (set in
`device/samsung/beyond1q/beyond1q_product_bind.rc`) and needs a **patched**
`libsec-ril.so`.

These were runtime-only adb hot fixes through Round 45 and were silently lost on
the Round 69 vendor rebuild — hence this tree copy.

## Files

| File | md5 | Origin |
|------|-----|--------|
| `bin/hw/rild` | `8eae286fc7aba3d3be6ae932dc6df2f3` | stock Samsung rild (16096 bytes), also at `vendor/samsung/sm8150-common/proprietary/vendor/bin/hw/rild` |
| `lib64/libsec-ril.so` | `ac4cfcdcbb64f810e8be10aa6154433e` | stock `libsec-ril.so` with the Round 44 `patchelf` DT_NEEDED/SONAME fix (unpatched stock is `41a68241…`) |

`libril_sem.so` is **not** here — it is already installed by the blob list
(`proprietary-files.txt` line 1494) and present in the built image.

## Injection

See the "Samsung stock rild + patched libsec-ril" section of
`../fix_vendor_mountpoints.sh`: writes `/bin/hw/rild` (mode 0755, label
`u:object_r:rild_exec:s0`) and `/lib64/libsec-ril.so` (mode 0644, label
`u:object_r:vendor_file:s0`).

## Verify after flashing

```sh
adb shell su -c 'md5sum /vendor/bin/hw/rild /vendor/lib64/libsec-ril.so'
adb shell su -c 'lshal | grep IRadio'   # expect 1.0…1.4 × slot1/slot2
```

## Rollback (runtime)

`/data/local/tmp/rild_los_before_fix`, `/data/local/tmp/libsec-ril.img_before_fix`
on the device hold the pre-fix (LOS rild / unpatched libsec-ril) copies.

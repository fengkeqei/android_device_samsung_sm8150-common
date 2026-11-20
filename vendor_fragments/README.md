# vendor_fragments

本目录的用途说明（v127 核对结果）。

## 真正参与构建

| 文件 | 引用方式 |
|---|---|
| `android.hardware.wifi.supplicant.xml` | `device/samsung/sm8150-common/Android.bp` 的 `vintf_fragment` 模块 `android.hardware.wifi.supplicant-v5.xml`，再由 `common.mk` 的 `PRODUCT_PACKAGES` 选中 |

## 历史遗留（不参与构建）

以下文件是本轮 bring-up 早期手工 `adb push` 到设备时留下的副本，**没有任何
`.mk`/`.bp` 引用**，保留只为对照原厂内容：

- `android.hardware.atrace@1.0-service.xml`
- `android.hardware.graphics.composer-qti-display.xml`
- `android.hardware.graphics.mapper-impl-qti-display.xml`
- `android.hardware.sensors@2.0-multihal.xml`
- `android.hardware.wifi.hostapd.xml`
- `power-samsung.xml`
- `vendor.qti.hardware.display.allocator-service.xml`

这些 HAL 的 VINTF 声明实际来自各自 soong 模块的 `vintf_fragments`（例如
`hardware/qcom-caf/sm8150/display` 的 composer/mapper/allocator 模块），
或者来自 vendor blob 自带的 `vendor/etc/vintf/manifest/*.xml`。

**注意**：不要把这里的文件加进 `PRODUCT_COPY_FILES`。kati 会直接报错：

```
VINTF metadata found in PRODUCT_COPY_FILES: ...
  use DEVICE_MANIFEST_FILE / DEVICE_MATRIX_FILE /
  vintf_compatibility_matrix / vintf_fragments instead!
```

要装 VINTF 片段，必须走 `vintf_fragment` 模块（见 `Android.bp`）。

# 本轮 bring-up 进度（2026-11-12 凌晨）

## 已完成并验证（设备 RF8N32EV43X 已生效）

1. **SELinux 补齐**：power/lights/keymint 三个 avium system 变体服务从
   `u:r:init:s0` 裸跑转为正确域：
   - `avium_power` / `avium_light` / `avium_keymint`
   - 域转换验证通过（`ps -AZ` 确认），三服务正常注册（IPower/ILights/IKeyMintDevice found），无 avc denial。
   - 涉及文件：`system/sepolicy/private/{file.te,file_contexts,hal_power.te,hal_light.te,hal_keymint.te,coredomain.te}`

2. **存储图库索引**：`storage_fix.sh` 开机全自动（卷挂载 + external_primary 注册 + FUSE 恢复）。
   - 干净 boot 验证：`emulated;0 mounted` + `content query external_primary` Row 0/1/2 + DCIM 照片可见。
   - 涉及文件：`device/samsung/sm8150-common/storage_fix.sh`

## WiFi（已定位根因，修复未完成）

### 根因（已确认）
- A16 的 WiFi framework 用 `ServiceManager.waitForDeclaredService`（**/dev/binder**）找
  AIDL ISupplicant；vendor 域的 wpa_supplicant 注册在 **vndbinder**，system_server 看不到
  （此 bp4a base 无 vendor-AIDL bridge）。
- 主 WiFi HAL 走 **HIDL** android.hardware.wifi@1.0（非 AIDL IWifi）：
  stock `android.hardware.wifi@1.0-service` 手动启动后成功注册 wifi@1.0~1.4 全部接口。

### 已完成的部分
- `fix_vendor_mountpoints.sh` 改为：删 AIDL `android.hardware.wifi-service.rc`，**保留** stock HIDL
  `android.hardware.wifi@1.0-service.rc`（此前逻辑相反）。
- SELinux：新增 `avium_supplicant` 域（coredomain + hal_wifi_supplicant），neverallow 排除已加
  （coredomain.te sysfs_leds/sysfs、domain.te sysfs_batteryinfo），`plat_sepolicy.cil` 构建通过。

### 未完成（障碍）
- supplicant avium-ization：`wpa_supplicant` 的 system 变体链接
  `libkeystore-engine`（→ android.system.keystore2 → android.hardware.security.keymint-V4-ndk，vendor 域），
  system 域无法链接 vendor keymint HAL。
  **方案（源码已就绪，未构建验证）**：
  - `certificate_utils.h/.cpp` 加 `CONFIG_AVIUM_NO_KEYSTORE2` 条件编译，stub `getKeystore2Cert`（返回 nullopt）；
  - Android.bp 新增 `libwpa_aidl_avium`（system 静态库，加 -DCONFIG_AVIUM_NO_KEYSTORE2，去 android.system.keystore2-V1-ndk）
    和 `wpa_supplicant_avium`（system cc_binary，去 libkeystore-engine-wifi-hidl + android.system.keystore2-V1-ndk）；
  - common.mk `wpa_supplicant` → `wpa_supplicant_avium` + PRODUCT_COPY_FILES `wifi_supplicant_avium.rc`（service 路径 /system/bin/hw/wpa_supplicant_avium）；
  - SELinux `avium_supplicant` 域已就绪（file_contexts 标记 /system/bin/hw/wpa_supplicant_avium）。
  **待办**：在内存充足机器 soong 构建验证（本机 14G thrashing 无法完成）；可能需在 fix 脚本删 vendor supplicant rc 避免 ISupplicant 双声明。
- **已验证不可行的运行时 hack**：给 vendor rc 加 `seclabel u:r:avium_supplicant:s0` 只能把进程 SELinux 域
  变成 avium_supplicant，但 ISupplicant 仍注册在 vndbinder —— AIDL 服务的 binder 域是**编译时**决定的
  （vendor 变体二进制内部用 vndservicemanager），运行时 seclabel 无法改变。必须重新编译 system 变体。

## 补丁转原生（部分完成）

- ✅ **manifest 已转原生并验证**：`DEVICE_MANIFEST_FILE` 指向合并文件
  `manifest_stock_backfill.xml`（= `manifest_stock_shell.xml` 头部 + `los_backfill.xml` 74 个 HAL 声明）。
  热部署到设备重启验证：boot=1、IPower/IKeyMintDevice found、0 crash、无 NULL VINTF。
  `fix_vendor_mountpoints.sh` 的 manifest debugfs 手术已移除。
- 注意：`los_backfill.xml` 是完整 `<manifest>` 格式（非 `<hal>` fragment），**不能**用
  `vintf_fragment` 模块（soong 分析卡死）；合并进 DEVICE_MANIFEST_FILE 是正确路径。
- 未做：vendor_libs（1010 个文件）、vendor_firmware、vendor_bins、gatekeeper、radio 的
  PRODUCT_COPY_FILES 化（改 .mk 触发 kati 重生成 ninja，依赖 soong 输出，同样受内存限制）。

## 构建环境问题（已部分绕过）

- soong **完整重分析**（删了 `out/soong/build.lineage_beyond1q.ninja` 缓存后触发）内存峰值
  ~38G 虚拟内存，本机 14G（无 swap、sudo 不可用），内存耗尽卡死。
- **绕过方法（已验证）**：用 `out/build-lineage_beyond1q.ninja`（1.5G 合并缓存，含 soong+make
  完整规则）直接 ninja 编译，手动补 `pool highmem_pool` 定义：
  ```
  builddir = out
  pool highmem_pool
   depth = 1
  subninja out/build-lineage_beyond1q.ninja
  subninja out/build-lineage_beyond1q-package.ninja
  ```
  成功编译出 system.img + vendor.img。
- 但**改 Android.bp 或 .mk 仍会触发 soong/kati 重分析**（卡死），所以需要改源码的后续工作
  （supplicant avium-ization、蓝牙、其余转原生）受阻于环境。

## 未做

- **蓝牙 TURNING_ON 卡住（根因已定位）**：蓝牙核心栈（HCI reset completed + BCM4375B1 firmware 加载 + GATT + adapter + A2DP/AVRCP profile 均启动）正常，
  `le_get_vendor_capabilities_handler invalid data v0.96` 是**非致命**日志（跳过 v0.96 解析）。
  真正卡住点是 `AudioSystem::listAudioPorts error -32`（音频 HAL 端口列表失败）→ AudioManager
  `updateAudioPortCache` monitor contention → A2DP `setProfileServiceState completed in 15006ms` +
  蓝牙音频 provider（A2DP/HearingAid）每 ~20s 反复 openProvider 重试。根源在 avium audio 服务
  （`android.hardware.audio.service-aidl.avium`，StreamLegacy backend 打开 vendor audio.primary.msmnile.so）
  的 IModule/listAudioPorts 返回 -32。修复需改 audio HAL 源码 + 重新构建（同样受阻）。
- 基带 ril 255、FBE 加密
- 其余转原生（vendor_libs 等）

## 续作（11-12 下午，14:14-15:05）

### 新增完成

6. **audio/effect avium 服务 SELinux 补齐**（此前两项服务 u:r:init:s0 裸跑）：
   - `avium_audio` / `avium_audioeffect` coredomain hal_server_domain（hal_audio 属性），
     exec 标签 avium_audio_exec / avium_audioeffect_exec。
   - neverallow 修复三处：domain.te vndbinder_device 排除两域；
     coredomain.te proc 排除 avium_audio；hal_audio.te 删冗余 r_dir_file(hal_audio, proc)
     （proc_asound 已单独授权）并把 vndbinder_use 收窄为 `{ hal_audio -avium_audio -avium_audioeffect }`。
   - 设备验证：域转换成功（ps -AZ），IFactory found、WiFi enabled、蓝牙 ON、图库 Row 0/1、0 avc denial。
   - 注意：plat_file_contexts 是独立构建目标（m plat_file_contexts），m plat_sepolicy.cil 不会刷新它。

### 累计清单状态

| 项 | 状态 |
|---|---|
| SELinux 补齐（health/power/light/keymint/supplicant/audio/audioeffect） | ✅ 全部设备验证 |
| 存储图库索引（开机全自动） | ✅ |
| WiFi（HIDL wifi@1.0 + wpa_supplicant_avium） | ✅ enabled + 扫描 |
| 蓝牙（audio.effect IFactory avium 化） | ✅ state ON |
| manifest 转原生（manifest_stock_backfill.xml） | ✅ |
| 警报监控（10min 无 adb 中文女声） | ✅ 实测播放 |
| 基带 ril 255 / FBE 加密 | ⏸️ 未做 |
| 其余转原生（vendor_libs 1010 文件等） | ⏸️ 未做 |

## 基带 bring-up（11-12 晚，15:00-21:00）

### ✅ 已达成

1. **modem 分区挂载**（原生修复）
   - 根因：`modem.mdt` 在独立的 `modem` 分区（sda18），不在 `apnhlos`；
     fstab 里该挂载被注释 → ueventd 找不到固件 →
     `subsys-pil-tz 4080000.qcom,mss: modem: Failed to locate modem.mdt(rc:-11)`。
   - 修复：`device/samsung/beyond1q/fstab.qcom` 取消注释 modem 挂载行。
   - 结果：`modem: Brought out of reset` + `Power/Clock ready interrupt received`，
     基带处理器首次启动。

2. **rild 运行 + HIDL IRadio 注册**
   - `rild` slot1/slot2 双实例 running。
   - `android.hardware.radio@1.0..1.4::IRadio/slot1,slot2` 全部 lshal 可见。
   - 曾验证 `gsm.sim.state=LOADED`、`gsm.version.baseband=G9730ZCU8HWE1`。

### 🔶 AIDL radio 桥（VoLTE 前置）—— 暂停

- **障碍**：`libradiocompat` 硬依赖 HIDL `V1_5::IRadio`；Samsung rild 只提供到 1.4；
  HIDL 的 `V1_5::IRadio::castFrom(V1_4)` 返回 null（不能跨版本升级）。
- 1.5 有独有方法（`setRadioPower_1_5`、`getBarringInfo`、`setDataProfile_1_5`、
  `setupDataCall_1_5`、`getDataRegistrationState_1_5` 等），全部降级需改 15+ 处类型/方法。
- 已尝试全局 `V1_5::IRadio` → `V1_4::IRadio`，编译报大量类型不匹配后回滚。
- 当前：compat 服务 rc 已禁用（移到 /data/local/tmp），避免崩溃循环。

### 🛡 本轮踩到并修复的 3 个 download 根因（重要教训）

1. **禁用文件必须移出目录，不能只改名**
   `/system/etc/init/radio-compat-avium.rc.disabled` 和
   `/system/etc/vintf/manifest/radio-compat-avium.xml.disabled` 仍被 init/servicemanager
   glob 到 → `Cannot add a device manifest to a framework manifest` →
   `NULL VINTF MANIFEST` → keystore2 崩 4 次 → `InitFatalReboot` → download。

2. **VINTF 同一 `<hal>` 块内不能混多个 major version**
   把 1.0/1.1/1.2/1.3/1.4 塞进一个块 → `Duplicated major version: 1.0 vs 1.1` →
   整个 device manifest 作废 → 同上崩溃链。
   正确做法：每个 major 一个独立 `<hal>` 块（已改为 5 块）。

3. **keymaster_aosp 缺少 file_contexts 规则**
   `/vendor/bin/hw/android.hardware.keymaster@4.0-service_aosp` 落在 `vendor_file`，
   init 无法域转换 → 服务 abort → keystore2（critical process）崩 → download。
   已加规则到 `system/sepolicy/vendor/file_contexts`。

### 新增 SELinux 域（本轮）

- `avium_radio`（coredomain + `hal_server_domain(hal_telephony)`）
  - 必须持有 `hal_telephony_server` 属性（vendor 侧 neverallow 要求），
    但把 11 条 vendor 特权 allow 规则收窄为 `{ hal_telephony_server -avium_radio }`
    （radio_device / efs_file / vendor_shell_exec / sysfs / cgroup 等），
    使 coredomain 不继承这些特权。
  - 额外给 `hwbinder_use` + `binder_call(avium_radio, hal_telephony_server)`。
- `avium_audio` / `avium_audioeffect`（coredomain + `hal_server_domain(hal_audio)`）
  - neverallow 排除：coredomain.te sysfs_leds/proc、domain.te vndbinder_device；
  - `hal_audio.te` 删冗余 `r_dir_file(hal_audio, proc)`（proc_asound 已单独授权），
    `vndbinder_use` 收窄为 `{ hal_audio -avium_audio -avium_audioeffect }`。

### 当前设备状态（21:00）

boot=1；6 个 avium 域全部正确（power/light/keymint/audio/audioeffect/supplicant）；
WiFi enabled；蓝牙 ON；存储 emulated;0 mounted；modem `Brought out of reset`；rild running。

### 下一步（独立任务）

AIDL radio 桥需要把 libradiocompat 从 HIDL 1.5 降到 1.4：
逐处处理 `setRadioPower_1_5`、`getBarringInfo`、`setDataProfile_1_5`、
`setupDataCall_1_5`、`getDataRegistrationState_1_5`、`getVoiceRegistrationState_1_5`
及其类型（DataProfileInfo / BarringInfo / RegStateResult / SetupDataCallResult 等），
或者反向让 rild 侧提供 1.5 包装。成本高，建议单独排期。

## 指纹/振动/声音/相机（11-12 深夜 - 11-13 凌晨）

### 振动 ✅ 已修复（avium 化成功）

- **根因**：`IVibrator/default` + `IVibratorManager/default` 注册在 vndbinder，
  system_server 在 /dev/binder 找不到。
- **修复**：新建 `android.hardware.vibrator-service.avium`（system 变体，
  `hardware/interfaces/vibrator/aidl/default/Android.bp`），直接写
  `/sys/class/timed_output/vibrator/enable`，无 vendor blob 依赖。
- SELinux：`avium_vibrator` 域 + `allow avium_vibrator sysfs_vibrator:file rw_file_perms`。
- 设备验证：服务 running、`IVibrator/default` + `IVibratorManager/default` 均 found、
  sysfs 写入 exit=0、VibratorManagerService 正常。
- 注意：需要把 AIDL 声明加进 device manifest（`manifest_stock_backfill.xml`）。

### 指纹 ❌ 无法 avium 化（已验证不可行）

- **根因**：`IFingerprint/default` 注册在 vndbinder（`hal_fingerprint_default` 域）。
- **尝试**：写好了 system 变体（含 sysprop shim 绕过 vendor sysprop_library 依赖），
  构建成功，但 **SELinux 硬阻止**：
  `neverallow coredomain vendor_file:file execute`
- 指纹 HAL 必须 dlopen `/vendor/lib64/libbauthserver.so`（QSEE TEE 传感器库），
  coredomain 禁止 execute vendor_file，这是 Treble 强制隔离，无法绕过。
- 已完整回滚改动。

### 声音 ⚠️ HAL 层正常，待确认症状

- AudioFlinger 两个 Output 线程正常、`StreamHalAidl` dump 正常。
- 音量 Max=15，路由正确：earpiece(voice_call) / speaker(system) / speaker(ring)。
- `attachedDevices` 含 4 项（Earpiece/Speaker/Built-In Mic/Built-In Back Mic）。
- **待用户确认**：是完全没声，还是特定场景（通话/媒体/铃声）没声。

### 相机 ⚠️ 4 设备全枚举，多摄配置受限

- `Number of camera devices: 4`，2 Back + 2 Front，全部 ADD 成功。
- S10+ 实际 5 摄（后置主摄+超广角+长焦 / 前置主摄+超广角），当前是逻辑相机
  （physicalIds 空），未暴露独立超广角/长焦。
- 需要 camera HAL 多摄配置调整（vendor blob 的 camera config）。

**04:5x 实测特征值（dumpsys media.camera）**：

| ID | facing | 焦距 | pixelArray | 说明 |
|----|--------|------|-----------|------|
| 0 | BACK | 4.3mm | 4032x3024 | 后主摄（logicalCameraType=9） |
| 1 | FRONT | 3.3mm | 3648x2736 | 前主摄 |
| 2 | BACK | 1.8mm | 4608x3456 | 超广角 16MP（独立暴露！） |
| 3 | FRONT | 3.25mm | ? | 前副摄（深度） |

- **长焦（~6.4mm 2x）完全未暴露**——传感器库在 /vendor/lib64/camera/
  （s5k3m3/imx 系列都有），但 HAL 没给设备 ID
- 主摄 `zoomRatioRange=[1.0, 8.0]`——**没有 0.5x**，所以 Aperture 的变焦 UI
  够不到超广角；Aperture 切镜头依赖 zoomRatio/logical 多摄
- `logicalCameraType=9` 仅主摄；无 LOGICAL_MULTI_CAMERA 能力、physicalIds 空
- **stock 里也没有 /vendor/etc/camera/**（tf_vendor_raw.img debugfs 确认），
  Samsung 多摄配置不是这个路径——uni HAL（uniplugin）的 ScemoParser 配置
  在别处或编译进 provider，需要抓 camera provider 运行日志定位
- 相机 app = LineageOS Aperture（org.lineageos.aperture）+ cameraextensions

## 指纹可见性回归根因与修复（11-13 05:xx）

**症状**：本轮启动 system_server 持续轮询
`android.hardware.biometrics.fingerprint.IFingerprint/default`（servicemanager
lazy-start 失败，1Hz），BiometricService 拿不到 HAL——这正是 03:38 那次
Watchdog 死亡的并发放大器。

**根因链**（/proc 证据）：

1. wrapper（hardware/samsung 的
   `android.hardware.biometrics.fingerprint-service.samsung`）是 `vendor:true`
   → 链接 VNDK → **libbinder 默认 binder 上下文 = /dev/vndbinder**
   （ProcessState.h 注释明说：VNDK 进程默认 vndbinder）
2. service.cpp 里 `SharedRefBase::make<Fingerprint>()`（内部 dlopen
   libbauthserver.so）先于 `AServiceManager_addService()` 执行，binder
   上下文早已定型
3. 于是 HAL 注册进了 vendor servicemanager；system_server 只查 system
   servicemanager → 永远看不到 → 轮询
4. 设备上实测：进程 fd3 = `/dev/binderfs/vndbinder`，
   `service list`（/dev/binder）只有框架自己的
   `android.hardware.fingerprint.IFingerprintService`

**修复**（已进源码树）：

- `hardware/samsung/aidl/fingerprint/service.cpp`：main() 第一个 binder
  动作改为 `android::ProcessState::initWithDriver("/dev/binder")`
  （first-call-wins，抢在 libbauthserver 之前钉死系统 binder）
- `Android.bp`：shared_libs 加 `libbinder`
- `system/sepolicy/vendor/hal_fingerprint_default.te`：`binder_use` +
  `allow ... hal_fingerprint_service:service_manager add`（设备当前
  permissive，热部署立即生效；进 enforcing 构建前需要这条）

部署脚本：/home/dev/Videos/Avium/deploy_fp_device.sh（kill 方式重启，
验证点 = `service list | grep IFingerprint` 出现 HAL 实例 + fd 变为
/dev/binder）。

## AIDL radio 桥完成（11-13 凌晨）

### ✅ VoLTE 前置全部打通

### ✅ VoLTE 前置全部打通

1. **libradiocompat V1_5 → V1_4 降级**（Samsung rild 只有 1.4）：
   - `CallbackManager.h/.cpp`、`RadioCompatBase.h/.cpp`、`service.cpp` 接口句柄 V1_5::IRadio → V1_4::IRadio
   - 1.5 独有方法处理：
     * 1.4 有对应版本：setRadioPower、setDataProfile_1_4、setInitialAttachApn_1_4、setupDataCall_1_4、
       setIndicationFilter_1_2、setLinkCapacityReportingCriteria（V1_2 AccessNetwork）
     * 1.4 无对应：getBarringInfo、getDataRegistrationState_1_5、getVoiceRegistrationState_1_5、
       setSignalStrengthReportingCriteria_1_5、setSystemSelectionChannels_1_5、startNetworkScan、
       areUiccApplicationsEnabled、enableUiccApplications、supplySimDepersonalization、
       sendCdmaSmsExpectMore → 全部 respond()->xxxResponse(notSupported(serial), ...)
   - 类型转换：`toHidlV1_4(DataProfileInfo)`（V1_0::ApnTypes 位图，mtu 合并）+
     `toHidlV1_4vec` + `toHidlStrings`（AIDL LinkAddress → 1.4 地址字符串）

2. **listManifestByInterface() 绕过**：该调用（hwservicemanager list）阻塞不返回，
   直接硬编码 slot1/slot2（lshal 已确认 rild 注册了两个 slot）。

3. **device manifest 修正**：AIDL radio 声明加进 `manifest_stock_backfill.xml`
   （IRadioConfig/default + 6 个 slot1 接口），HIDL radio 拆分为 5 个 major 独立块。

4. **libeffectconfig / libvibrator 等库链接**：库文件必须拷到
   `/system/lib64/`（linker 搜索路径），不能只放 `/system/lib64/hw/`。

### 设备验证结果（凌晨 02:26）

- `radio-compat.avium` 服务 running（avium_radio 域）
- AIDL 7 接口全部注册 /dev/binder：IRadioConfig/default +
  IRadioData/Messaging/Modem/Network/Sim/Voice slot1
- `gsm.sim.state = LOADED`，`gsm.operator.numeric = 46002`（SIM 已读）
- `gsm.operator.alpha = CMCC`，`gsm.network.type = LTE`（**已注册 LTE 网络**）
- `mServiceState = IN_SERVICE`（slot1）
- IMS 栈全部启动（imsstack/imsmedia/imsserviceentitlement）
- `LteVopsSupportInfo: mVopsSupport = 1`（VoLTE 网络支持确认）

### 教训（新增）

- **分区 auto-remount 回 ro**：deploy 脚本每次开头都必须 `mount -o rw,remount`，
  否则 cp 静默失败（exit 0 但文件没写）。
- **/data/local/tmp 的旧文件**：用同名文件推送新版本时确认 md5，旧版本会覆盖修复。
- **linker 库搜索路径**：DT_NEEDED 的 .so 必须在 `/system/lib64/`（不能只在
  `/system/lib64/hw/` 子目录）。

## 声音/文件诊断结论（11-13）

### 声音 ⚠️ 链路正常，待用户实测

- AudioFlinger 2 个 Output 线程正常（AudioOut_D/15，HAL 4096 帧 PCM16 48k 立体声）
- AudioPolicyManager：Speaker 端口正常（Available output devices 2 个，路由 Mix→Speaker）
- 音量 STREAM_MUSIC max=25 current=13，非静音
- **根因（历史）**：com.android.phone 在 PhoneFactory.makeDefaultPhones 阻塞于
  `ServiceManager.waitForDeclaredService(IRadioConfig/default)`（compat 桥未启动时
  声明了但无人注册）→ phone 反复启动失败 14 次 ANR → system_server 拖死 →
  设置音量拖动卡死 + 音频请求全被吞
- **radio compat 桥部署后 phone 已恢复**：pid 存活、不 ANR、AudioService dumpsys 响应正常
- shell 触发的 intent 播放无法产生 AudioTrack（系统音效策略依赖 UI 层交互），
  **需要用户在设备上实测**：拖音量/播放音乐/按键音

### 文件管理器 ✅ 已恢复

- Files（documentsui）运行中，`/sdcard/` 标准目录（Alarms/DCIM/Documents...）可见，
  DCIM/Camera 有照片文件
- 「看不到文件夹」应随 phone 崩溃风暴解除而恢复，待用户确认

### 教训补充

- `com.android.phone` 是 telephony 栈的入口，radio HAL 不可达时它会阻塞在
  `PhoneFactory.makeDefaultPhones`，进而拖死整个 system_server 的相关调用
  （包括设置音量 UI 和 MediaProvider 的部分回调）——表现为完全无关的
  「声音没了」「设置卡死」「文件看不到」。

## 声音/文件/指纹最终诊断（11-13）

### 声音 ✅ 实测播放成功

- **AudioTrack 实测**：app_process 创建 AudioTrack（440Hz 正弦波，3 秒），
  AudioOut_D 线程 Standby: no（激活），PCM hw_params 配置成功（S16_LE/48k/2ch），
  播放日志 "PLAYING for 3s / DONE"。
- **根因（历史）**：com.android.phone 在 `PhoneFactory.makeDefaultPhones` 阻塞于
  `ServiceManager.waitForDeclaredService(IRadioConfig/default)`（radio compat 桥
  未启动时声明了但无人注册）→ phone 反复启动失败 14 次 ANR → system_server 被拖死。
- **radio compat 桥部署后 phone 已恢复** → 音频链路（AudioPolicyManager →
  Speaker 端口 → AudioOut 线程 → PCM）全部就绪。
- ANR 记录：`/data/anr/` 有 14 个 "com.android.phone failed to complete startup"。
- dumpsys audio / media.audio_flinger / media.audio_policy 全部正常响应。

### 文件管理器 ✅ 已恢复

- Files（documentsui）运行中，`/sdcard/` 标准目录可见（Alarms/Android/Audiobooks/
  DCIM/Documents/Download/Movies），DCIM/Camera 有照片。
- MediaProvider 运行中，`content query` 正常返回（含 recovery 日志文件）。
- 「看不到文件夹」随 phone 崩溃风暴解除而恢复。

### 指纹 ✅ vendor 侧方案确认可行

- samsung 指纹服务（`android.hardware.biometrics.fingerprint-service.samsung`）
  运行在 vendor 域（`hal_fingerprint_default`），使用 vendor sepolicy
  （`hal_fingerprint_default.te`：efs_file + uhid_device + tee_device）。
- `IFingerprint/default` AIDL 接口已注册，device manifest 已声明
  （`android.hardware.biometrics.fingerprint` V4）。
- **system_server 已可见**：`dumpsys biometric` 显示
  `Sensors: ID(1008), modality 8(fingerprint), state 0(ready)`。
- 之前不可见的原因：phone 阻塞导致 biometric 服务无法扫描 HAL。
- avium 化尝试已回滚（vendor dlopen libbauthserver.so 与 coredomain 禁止
  execute vendor_file 冲突，用户确认按 vendor 侧修法）。

### 原生设备树转换 ✅ 全部完成

所有修复均已入源码树（PRODUCT_PACKAGES / PRODUCT_COPY_FILES / 源码修改），
下次全量构建自动打包：

| 修复 | 原生形式 |
|---|---|
| modem 分区挂载 | `fstab.qcom`（取消注释） |
| AIDL radio 桥 | `PRODUCT_PACKAGES += android.hardware.radio-service.compat.avium` |
| 振动 avium | `PRODUCT_PACKAGES += android.hardware.vibrator-service.avium` |
| audio effect avium | `PRODUCT_PACKAGES += android.hardware.audio.effect.service-aidl.avium` |
| wpa_supplicant avium | `PRODUCT_PACKAGES += wpa_supplicant_avium` + PRODUCT_COPY_FILES |
| device manifest | `manifest_stock_backfill.xml`（含 AIDL radio + AIDL vibrator 声明） |
| SELinux 域 | avium_radio/audio/audioeffect/vibrator/supplicant/health/power/light/keymint |
| fingerprint vendor sepolicy | `hal_fingerprint_default.te`（已有，无需改） |

### 当前 OUT_OF_SERVICE 说明

**已实现（2026-11-13 03:2x，待部署验证）**：V1_2 注册状态转换已写入源码树。

- `network/RadioNetwork.cpp`：`getDataRegistrationState` / `getVoiceRegistrationState`
  在 mHal1_6 为空时降级调用 `mHal1_5->getDataRegistrationState(serial)`
  （mHal1_5 实际持 IRadio 1.4，继承自 1.2 的方法）
- `network/structs.{h,cpp}`：新增 `toAidl(V1_2::DataRegStateResult)` /
  `toAidl(V1_2::VoiceRegStateResult)` / `toAidl(V1_2::CellIdentity)`：
  - regState/rat/reasonForDenial 直接映射（data 用 reasonDataDenied）
  - registeredPlmn 置空（1.2 无此字段）
  - V1_2 CellIdentity 是 struct+5 个 vec（非 safe_union），按 cellInfoType
    拆包填入 V1_5 safe_union，复用已有 `toAidl(V1_5::CellIdentity)`
  - **LTE 时合成 EutranRegistrationInfo{vops=true, emc=false, nr 全 false}**：
    V1_2 不带 vops 位，若留 noinit 框架会把所有 LTE 小区当 VoLTE 不可用；
    vendor IMS 栈已实测 mVopsSupport=1，故按此合成
- `network/RadioResponse-network.cpp`：`getDataRegistrationStateResponse_1_2` /
  `getVoiceRegistrationStateResponse_1_2` 从空 stub 改为真正转发
- 已知遗留：`getCellInfoList` 降级到 1.0 方法但其 1.0 响应是空 stub（信号条
  走 getSignalStrength_1_4 正常，仅影响邻区信息），后续如需再补 _1_2 链

**补充（03:5x 实测发现）**：Samsung rild 对 DATA 查询即使收到 V1_2 请求也用
`getDataRegistrationStateResponse_1_4` 回调（语音则按规矩用 _1_2），导致
DATA_REGISTRATION_STATE 全部被空 stub 丢弃、WAKE_LOCK_TIMEOUT。已补
V1_4 路径：请求改调 `getDataRegistrationState_1_4`，新增
`toAidl(V1_4::DataRegStateResult)`（V1_2 base + VopsInfo 联合，LTE 无
vops 信息时仍合成 vops=true）。部署脚本改用 killall 让 init 自动重启。

### 04:xx 事件：runtime restart → BPF 地图丢失 → system_server 死循环

03:38 一次 runtime restart（疑与旧 toolbox `stop` 工具的 ctl.stop 链有关，
`Processed ctl.stop for 'zygote_secondary'`）之后：

1. SurfaceFlinger 死亡 → 每个新 system_server 卡死 StartDisplayManager
   等 SF → Watchdog 杀 → 循环（手工 `setprop ctl.start surfaceflinger` 解）
2. netd BPF 地图被清（/sys/fs/bpf/net_private 空、local_net_access 缺失），
   BpfNetMaps.initBpfMaps 抛 `nativeDeleteMapEntry failed: ENOSYS` →
   system_server 必崩（每 20 秒一次死循环，crash 缓冲可见完整栈）
3. netbpfload 重跑失败：root 模式要求 bpffs 零程序（bpfGetNextProgId 必须
   ENOENT），gpuservice 持有的 gpuMem prog 是 legacy attach（进程死了也不
   释放）→ exit 32。**干净重启是唯一解**：重启后 NetBpfLoad success，全部
   地图恢复，框架正常起来。

**教训**：本 ROM 热部署时绝不用旧 toolbox 的 `stop`/`start` 工具重启任何
服务；改用 `killall <进程名>`（init 自动重启非 oneshot 服务）或
`setprop ctl.stop <精确服务名>`。

### 重启后状态（04:1x）

- NetBpfLoad success（启动 8.5s），local_net_access 地图在 netd_shared
- system_server 稳定，com.android.phone 存活（2576）
- 注册状态从 OUT_OF_SERVICE → POWER_OFF（radio 未上电，等框架自动上电）
- V1_2 语音注册转换已验证工作：RILJ 收到
  `RegStateResult{regState: NOT_REG_MT_SEARCHING_OP...}`（SST/NRM 正常消费）

### OUT_OF_SERVICE 的原因（详细）

`getDataRegistrationState_1_5` / `getVoiceRegistrationState_1_5` 返回 notSupported。
1.4 HAL 有继承的 `getDataRegistrationState`（从 1.2），但 compat 层的
`RadioResponse::getDataRegistrationStateResponse_1_2` 是空 stub（"IRadio HAL 1.2
not supported"）。降级到 1.2 版本和 notSupported 效果等同。

**需要的实际工作**：实现 `V1_2::DataRegStateResult` / `V1_2::VoiceRegStateResult`
到 AIDL `RegStateResult` 的转换（已有 V1_5/V1_6 版本的转换可参考）。
或者让 rild 侧支持 1.5 方法。这是独立的开发任务。

另外 Samsung RIL 的 OEM 扩展（`secOemNoti: sehBridgeService == NULL`）需要
Samsung 特有的 telephony 扩展框架连接，这是 Samsung 设备 bring-up 的额外工作。

## 11-13 下午：指纹 -129 根因 + cell info 堆积（本轮）

### ✅ 指纹 HAL 注册 -129 根因彻底定位并修复

**根因（实锤对照实验）**：

系统上存在**两份 libbinder**，wire-format 头不同：

| 库 | 大小 | parcel 头 |
|---|---|---|
| `/system/lib64/libbinder.so` | 919216 | `SYST`（0x53595354） |
| `/vendor/lib64/libbinder.so` | 898328 | `VNDR`（0x564e4452） |

头由编译期宏决定（`frameworks/native/libs/binder/Parcel.cpp:1099-1107`）：
```
#if defined(__ANDROID_VNDK__)  → VNDR
#else                          → SYST
```
而 soong 对 vendor 分区模块自动加 `-D__ANDROID_VNDK__`
（`build/soong/cc/compiler.go:477`，`ctx.InVendorOrProduct()`）。

指纹服务是 `vendor: true`，默认解析到 `/vendor/lib64/libbinder.so`，
写的 parcel 头是 `VNDR`；system servicemanager 只认 `SYST`，于是：

```
servicemanager: libbinder.Parcel: Expecting header 0x53595354 but found 0x564e4452.
                Mixing copies of libbinder?
fingerprint-service: AServiceManager_addService(...) returned -129  (EX_TRANSACTION_FAILED)
                     Check failed: status == STATUS_OK  → SIGABRT → 重启循环
```

**决定性对照实验（同一二进制，只改库搜索路径）**：

| 条件 | 结果 |
|---|---|
| 默认（vendor libbinder） | `returned -129` + `Mixing copies` |
| uid 1000 + `LD_LIBRARY_PATH=/system/lib64` | **`returned 0`**，`/proc/PID/maps` 证实加载 `/system/lib64/libbinder.so` |

**修复（设备树原生形式）**：
`hardware/samsung/aidl/fingerprint/android.hardware.biometrics.fingerprint-service.samsung.rc`
```rc
    env LD_LIBRARY_PATH /system/lib64:/vendor/lib64
```
让该进程优先解析系统版 libbinder（`SYST` 头），注册进 system servicemanager。

**注意**：此 env 只在 init 解析 rc 时生效，**重启后**才应用到服务。
（曾误判为 AT_SECURE 会屏蔽 LD_LIBRARY_PATH —— 实测该服务 uid 1000
进程的 AT_SECURE 为 0，路径生效。）

**回滚记录**：本轮曾误改 `service.cpp` 加
`ProcessState::initWithDriver("/dev/binder")` 且让二进制显式链接
`libbinder`——这会让二进制直接绑定 vendor 版 libbinder，反而放大问题
（显式 DT_NEEDED 让 vendor 库优先）。已 `git checkout` 还原。

### ✅ cell info 响应空 stub → RILJ 请求堆积（基带阻塞根因）

**症状**：`logcat -b radio | grep -c GET_CELL_INFO_LIST` = **2068**，
同一秒内堆积数十个请求，全部无响应 → RILJ 主线程队列被堵死 →
PollState 无法推进 → `mServiceState = OUT_OF_SERVICE`、信号全 `INT_MAX`。

**根因**：Samsung rild 只实现 HIDL IRadio 到 1.4，对 `getCellInfoList`
**即使收到低版本请求也用 `getCellInfoListResponse_1_4` 回调应答**，
而 `network/RadioResponse-network.cpp` 里该回调是空 stub：

```cpp
Return<void> RadioResponse::getCellInfoListResponse_1_4(..., const hidl_vec<V1_4::CellInfo>&) {
    LOG_CALL << info.serial;
    LOG(ERROR) << "IRadio HAL 1.4 not supported";   // ← 响应被丢弃
    return {};
}
```

**修复（三处，进设备树）**：

1. `network/structs.h`：声明 `toAidl(const V1_4::CellInfo&)`
2. `network/structs.cpp`：实现转换器
   - `V1_4::CellInfo::Info` 是 safe_union；GSM/CDMA/WCDMA/TDSCDMA 臂
     仍是 V1_2 类型，LTE 臂为 `V1_2::CellInfoLte + CellConfigLte`，
     NR 臂字段名是小写 `cellidentity` / `signalStrength`
   - 各臂重新包成 V1_5 形状后复用既有 V1_5 转换器
     （`cellConfig` 在 framework 消费的结构里无对应字段，按设计丢弃）
3. `network/RadioResponse-network.cpp`：`getCellInfoListResponse_1_4`
   改为真实转发 `networkCb()->getCellInfoListResponse(toAidl(info), toAidl(cellInfo))`

**设备验证**：
- 新库 md5 `0aae3713` 部署到 `/system/lib64/android.hardware.radio-library.compat.avium.so`
- 重启 phone 后 25 秒窗口：CELL_INFO 请求 **28**（修复前 2068 堆积），
  `getCellInfoListResponse_1_4` 正常回调（serial 实时递增）
- RILJ 恢复消费真实响应：`regState: NOT_REG_MT_SEARCHING_OP`（CS 搜网中）

**遗留**：modem 仍未驻留 CMCC（`ril.currentplmn=unknown`，信号
`INT_MAX`）。请求通路已通，剩下是 modem 侧射频/驻留问题，与
`setRadioPower on 1` 已成功往返无关。

### 相机多摄（结论：结构性限制）

- 4 个相机 ID 全部枚举成功（后主 4.3mm / 超广角 1.8mm / 前主 3.3mm / 前副 3.25mm）
- 4 台的 `android.control.zoomRatioRange` 均为 `[1.0, 8.0]` —— **没有 0.5x**
- 后置长焦完全未暴露
- 已确认 **stock vendor 镜像里也没有 `/vendor/etc/camera/`**
  （`debugfs -R "ls /etc/camera" /home/dev/Videos/Avium/vendor_extract/vendor.img.raw`
  → `File not found`）；Samsung uni-HAL 的多摄配置编译进
  `camera.qcom.so` / `univhal` 内部或走其它路径
- **无配置源可用 → 记录为已知限制，不作为本轮目标**

### 本轮构建环境记录

`beyond1q` 的 soong **完整重分析**（改 Android.bp 后必触发）：
- 本机 14G 物理 + 51G swap（zram 29G + swapfile 22G）
- 实测：CPU 累计 ~4 小时、wall 约 **33 分钟**、RSS 峰值 ~6G、
  VSZ ~45G、写出 ~8GB ninja
- **结论：现在能跑完**（历史"卡死"是过早 kill 所致；耐心等 33 分钟即可）
- 完成后进入 ninja 编译 5841 任务，约 15 分钟

### 请求-响应闭环验证（14:24）

修复后实测 45 秒窗口：

```
requests  = 60
responses = 15   （每次 _1_4 回调可批处理多个 serial）
sample:
  NetworkResponse.getCellInfoListResponse_1_4 234
  RILJ: [0234]< GET_CELL_INFO_LIST error 63 (NO_NETWORK_FOUND)
```

关键差异：修复前请求**永不完成**（无限堆积 2068 个）；
修复后每个请求都以明确结果结束（当前 `NO_NETWORK_FOUND` 是
modem 未驻留的真实状态，属正常错误上报路径）。
RILJ 队列不再堵塞，PollState 可正常推进。

### 本轮最终设备状态（RF8N32EV43X）

| 功能 | 状态 |
|---|---|
| boot_completed | 1 |
| WiFi | enabled |
| 蓝牙 | state ON |
| 存储 | emulated;0 mounted |
| 振动 | IVibrator/default found |
| keymint | IKeyMintDevice/default found |
| power | IPower/default found |
| lights | android.hardware.light.ILights/default found |
| health | IHealth/default found |
| audio core | IModule/default found |
| camera | 4 devices（长焦/0.5x 见上，无配置源） |
| radio AIDL | IRadioConfig/default + 13 接口 found |
| 指纹 HAL | IFingerprint/default 注册成功（`returned 0`） |
| 蜂窝注册 | ⏸ modem 未驻留（请求通路已修通） |

## 11-13 晚：基带不注册的完整根因（重大突破）

### 一、根因链（全部有机上证据）

```
sehradiomanager 从未编译/打包（missing from PRODUCT_PACKAGES）
        ↓
没有进程调用 RIL_RegisterSehBridge
        ↓
Samsung rild 的 mSehBridgeIndication == NULL
        ↓
BuildUnsolicited: IPC message 20. truncated.   ← 89/89 全丢（100%）
secOemNoti: sehBridgeService[0]->mSehBridgeIndication == NULL
QC-DS-LIB: OnUnsolicitedResponse: No Registered Clients
        ↓
rild 的 mIsDeviceReadyNotiNeed = NOT_CONNECTED
        ↓
InitiateNetworkSelection 调用次数 = 0
        ↓
modem 从未收到搜网指令 → 信号全 INT_MAX / NO_NETWORK_FOUND / operator 空
```

**关键**：`reg[2]` 日志出现 84~89 次，但都是 **QMI NAS 缓存的上次启动残留**，
`[FINAL-PS]` 归零才是真实状态（51/51 次全 0）。

### 二、修复过程与三个真实 bug

**修复 1：sehradiomanager 未入包**
- `device/samsung/sm8150-common/common.mk` 加 `PRODUCT_PACKAGES += sehradiomanager`
- 注意：soong 完整重析需 ~30 分钟（本机 14G 物理 + 51G swap）

**修复 2：sehradiomanager 崩溃（生命周期 bug）**
- 崩溃：`SIGSEGV` in `BnHwSehRadioResponse::_hidl_setVendorSpecificConfigurationResponse+168`
- 原因：`samsungIndication`/`samsungResponse` 是**循环体局部 `sp<>`**，
  循环迭代结束即析构，而 rild 只保存裸指针 → 回调即空指针
- 修复：提到循环外的 `std::vector<sp<...>>` 保持强引用

**修复 3：ril-daemon（slot1）永久 stopped**
- 症状：`init.svc.ril-daemon = stopped`，且 `starting service 'ril-daemon'` 计数 = 0
- 原因：Samsung rild 需要 clientId 参数。`ril-daemon1` 定义是
  `/vendor/bin/hw/rild -c 2`，而 `ril-daemon` 原先**无参数** →
  rild 启动后 40ms exit 255（无任何日志）
- 修复：`/vendor/etc/init/init.vendor.rilchip.rc` 改为
  `service ril-daemon /vendor/bin/hw/rild -c 1`（与 slot2 对称）
- **效果：slot1/slot2 双 rild 现在都 running**

**修复 4：setVendorSpecificConfiguration 触发崩溃（进行中）**
- 即使加了生命周期修复，`Done (slot1)` 后 40ms 仍 SIGSEGV
- 崩溃点固定在 `_hidl_setVendorSpecificConfigurationResponse`，fault addr 0x0
- 判断：该 HIDL 回调链本身有问题（stock rild 侧行为），而它携带的 vendor
  config 是**可选**的（服务本身有 `FW_READY=1` 默认值）
- 修复：注释掉 `svc->setVendorSpecificConfiguration(...)`，只保留
  `setResponseFunction`（这才是让 `mSehBridgeIndication` 非空的调用）

### 三、已验证修复的两项（与本轮无关但重要）

- **指纹 HAL**：rc 加 `env LD_LIBRARY_PATH /system/lib64:/vendor/lib64`
  → 重启后 `dumpsys biometric` 显示 `Sensors: ID(1008), modality 8, state 0`
  （根因：vendor 版 libbinder 写 `VNDR` parcel 头，system SM 只认 `SYST`）
- **指纹崩溃连锁**：`CHECK(status == STATUS_OK)` 改软失败 → 不再触发
  `UPDATABLE_CRASHING` → 不再连坐重启 rild/其他 updatable 服务

### 四、5G UI 移除（已定方案）

- 设备 `RadioCapability.raf = 381831`（bit20 NR = 0），**硬件无 5G**
- 但 AOSP `CarrierConfigManager` 默认把
  `carrier_nr_availabilities_int_array` 置为 `{NSA, SA}`，
  Settings 因此画出 5G 选项
- 修复：`packages/apps/CarrierConfig/res/xml/vendor.xml`
  在每个 `<carrier_config>` 块加
  `<int-array name="carrier_nr_availabilities_int_array" num="0"/>`
  （空数组 = "运营商不支持 5G"，AOSP 官方表达方式）
- 消费端已确认安全：`GsmCdmaPhone.updateNrSettingsAfterCarrierConfigChanged`
  用 `!ArrayUtils.isEmpty(nrAvailabilities)` 判定


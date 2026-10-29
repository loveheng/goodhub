# 端侧引擎原生库与模型资产落位说明（on-device · S3 geniex-android 换线后）

> **当前状态（2026-10-29 S3 换线）**：本目录**不再放置任何 `.so`**——推理
> 后端 = 官方 `geniex-android` 0.3.5 AAR（Maven
> `com.qualcomm.qti:geniex-android`，官方 GenieX Chat 同款管线），自带 QNN
> 2.45 运行时全家桶（libQnnHtp/libQnnHtpV79Stub/libQnnHtpV79Skel/
> libQnnSystem/libQnnHtpNetRunExtensions 等）与 libgeniex-proc 调度层，随
> APK 构建自动并入。旧手捆 QAIRT 2.51 五库（含 libGenie.so）已移除（备份
> `/tmp/jnilib-backup2/`，QAIRT SDK 源在 `~/Downloads/ai/qairt/`）。
>
> 换线依据：4B 同资产同参数三方法对照钉死裸 libGenie C API 存在 2.5× 运行
> 时管线代差（官方 App 22.96 tok/s vs 参考件与旧实现 111.7ms 逐位一致）；
> 换线后终验 21.56/20.60/24.01 tok/s（详见 on-device epic devlog）。

## 构建期处置

- `libQnnHtpPrepare.so`（87MB，离线图编译用）经 `build.gradle.kts`
  `packaging.jniLibs.excludes` 排除（S2-5 A/B 实证运行时不加载）。
- `proguard-rules.pro` keep `com.geniex.sdk.**`（AAR 无 consumer 规则，
  JNI 按名反射面）。

## 模型资产落位（不变 + 新要求）

- 设备侧落盘：App `filesDir/models/<model-id>/`（OTA 通道：manifest 分发 +
  sha256 校验 + 原子替换 + 磁盘门禁，§4.5/§4.6/§4.8）。
- **geniex-android qairt 插件 dispatch 强制要求资产含 `metadata.json`**
  （dispatch.h modelIdOf 读编译规格；裸 Genie C API 时代不需要）——新资产
  入目录清单必须含此件，缺失即创建失败 -100201。
- `genie_config.json` 路径形态不限（App 侧解析时不重写，管线按 cwd 无关的
  绝对路径构造）；4B 包无 `max-num-tokens` 上限，测量场景须显式上限。

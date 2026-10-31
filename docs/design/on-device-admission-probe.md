---
status: draft
updated: 2026-11-01
---

# 端侧准入探针与 DispatchProfile 调度画像

> 状态：draft（2026-11-01 与 P0#1 坏后端记忆合并拍板）。设计 SSOT 关联 `context/epics/on-device/memory.md`（已锁定：NPU→GPU→云回退链、CPU 出局、DispatchProfile 合并决策）。
> 关联：`on-device-npu-deployment.md`（v3.2 NPU 兜底被本稿推翻）、`on_device_asset_manager.dart`（驱动指纹失效）、`on_device_capability.dart` / `HybridCloudEngine`（Dart 路由查表）。

## 0. 设计目标

把「运行时故障检测」前移为「导入时准入审核」：在模型文件落盘后、用户发起会话前，于后台空闲/充电态用 `:engine` 隔离进程完成一次确定性体检，固化该模型在本机（按驱动指纹）的调度决策树。后续用户点击使用时执行零开销查表调度，从根本上消除「聊到一半因 NPU 驱动报错被误杀」的误判。

## 1. DispatchProfile 数据契约

```
key   = "<modelId>#<Build.FINGERPRINT>"
value = {
  "probedAt":  <epoch_ms>,
  "backends": {
    "NPU": { "verdict": "HEALTHY|EXCLUDED|ERROR", "reason": "...", "ttftMs": <int>, "memBytes": <int> },
    "GPU": { "verdict": "HEALTHY|EXCLUDED|ERROR", "reason": "...", "ttftMs": <int>, "memBytes": <int> }
  }
}
```

- **键含 `Build.FINGERPRINT`**：驱动 OTA 后指纹漂移 → 画像整体失效，复用 `asset_manager.recoverIfDriverChanged` 一并脏删重探。
- **双 verdict 同体**：真实 dispatch policy 需要 `Primary`/`Fallback`，故 NPU 与 GPU 必须同时承载，禁止只写单条 `{"backend":"GPU"}`。
- **reason 取值**：`TIMEOUT` / `OP_NOT_SUPPORTED` / `ZERO_OUTPUT` / `CRASH` / `DRIVER_INCOMPATIBLE`；由 `:engine` 墓碑排除法补充归因。

## 2. 存储落点

- 文件：模型目录内 `.admission.json`（与 `.asset-meta.json` 同目录，沿用 `getApplicationSupportDirectory()/models/<dirName>/`）。
- **严禁 `getCacheDir()`**（§4.6 静默清空会 SIGBUS）。
- 管理归属：`OnDeviceAssetManager` 负责写入/读取/指纹失效清理，使准入画像与资产生命周期同源。

## 3. 触发契机

- **时机**：`asset_manager` 落盘 + 指纹记录**之后**，后台空闲或充电态触发，绝不挡 UI。
- **设备门禁**：仅 `D1` 通过的高端 NPU 设备触发；中低端本就收口纯云，不跑探针浪费。
- **进程模型**：复用 `:engine` 独立进程（不新开第三进程）；探针崩/被 LMK 杀仅重探，不碰主进程。
- **重探条件**：指纹漂移、画像缺失、导入/重导后 `modelId` 变化。

## 4. 执行协议（探针核心）

1. `load` 模型于目标后端（NPU 优先，NPU 败再探 GPU 建立 Fallback）。
2. **真生成微基准**：固定极简输入 `"hi"`，`max_tokens=1`，带**硬超时 5~10s**。
   - 纯 `load` 不足够——必须真生成才能抓「成功就绪但首字 0 + 驱动挂起」。
3. **有效性校验**：`token_id` 必须可合法反解且非空（排除静默零产出 `ZERO_OUTPUT`）。
4. **裁决固化**：
   - 出字合法 → `HEALTHY`，记录 `ttftMs` + `memBytes`；
   - 超时/崩溃/零产出 → `EXCLUDED`/`ERROR` + `reason`。
5. **探针后驱逐**：`onRelease` → `COLD`，**不常驻**（省 ~1.9GB），用户首次真实使用重新懒加载。

### 4.1 生产探针 vs Spike 探针

- **Spike 阶段**：1-token 仅验证管道通，允许硬编码单条画像。
- **生产准入探针**：须 `max_tokens≥8`（或跑至 ~50 token）作二级校验——首字通过但 mid-sequence 才暴露的 Softmax 溢出 / FastRPC 超时，1-token 会假绿。

## 5. 状态机落位

- **探针状态（独立，不与引擎主状态机耦合）**：`PENDING → PROBING → HEALTHY | EXCLUDED | ERROR`。
- **与引擎生命周期解耦**：探针走 `COLD → WARM(load) → probe → onRelease → COLD`，独立于用户会话的 `WARM_STANDBY/ACTIVE` 与 5min TTL；不污染会话态。

## 6. Dart 侧路由查表（零开销分流）

- `HybridCloudEngine` / `on_device_capability.dart` 在装载决策前读 `DispatchProfile`：
  - `NPU.HEALTHY` → 首选 NPU；
  - `NPU.EXCLUDED` 且 `GPU.HEALTHY` → 直落 GPU，不拉 NPU 踩坑；
  - 两者皆 `EXCLUDED`/`ERROR` → 显式 `[DEGRADE]` 切云。
- **直接跳过坏后端**：不再让 `:engine` 死一次来确认，查表即决策。

## 7. 与现有机制边界

| 机制 | 关系 |
|---|---|
| 两级熔断 `on_device_circuit_breaker` | **不合并**（进程级/时间窗严重度，正交） |
| `MemGate` 水位 / `DeviceTierGate` | 保留装载门禁；画像 `memBytes` 与 MemGate 阈值对账 |
| `:engine` 墓碑死因 | reason 字段由墓碑排除法补充 |
| P0#1 运行时坏后端记忆 | **即本画像的第二个写入方**（运行时崩溃/零产出 → 标 `EXCLUDED`），与导入探针共享同一 `DispatchProfile` |

## 8. 回退链物理执行

```
NPU(QAIRT) → GPU(llama_cpp+GPU) → 云端 [DEGRADE]
```

- CPU **彻底出局**；触发条件：① QAIRT build 失败 → GPU；② 首字零产出/负状态码（`chunks==0 && status<0`，复用 `EngineService` benchChunks 对账）→ 单次 GPU 兜底 + 标 NPU `EXCLUDED`；③ 热(≥SEVERE)/OOM → 云（GPU 亦不兜底）。
- **CPU 代码路径删除时机 = GPU Spike 全绿后**；Spike 未过期间 CPU 分支置 inert（保留代码、路由不走），回退链临时 = NPU→云。

## 9. 验收口径（Spike → 合流）

Spike 有界验证 4 指标（基线 = 真实在售 1.5B Q8 GGUF）：
1. **Shader 编译落盘**：首次编译稳定完成，产物落 `filesDir` 私有目录；二次装载命中缓存（数十秒→1~2s）。
2. **内存物理包络**：真实 RSS/VmHWM 峰值 + 显存释放彻底性，对照 MemGate 水位不冲 LMK。
3. **1-token 微基准**：`"hi"` 合法首字节反解（TTFT 以测到为准，300~800ms 仅假设非门槛）。
4. **异常确定性（否决性门槛）**：显存人为超限/驱动报错须抛**结构化异常码**，不得不可捕获 SIGSEGV 打挂 `:engine`；此条不过 GPU 档不能作下限。

通过后即时动作：① 撕 `memory.md` 断点 UNCERTAIN；② 探针逻辑合流 `lib/llm/on_device_admission_probe.dart` + `:engine` `probeBackend`；③ 物理删除 CPU 代码路径，硬编码 NPU→GPU→云。

## 10. 落点清单

- 新增 `lib/llm/on_device_admission_probe.dart`（Dart 编排：空闲/充电触发、读/写画像、设备门禁）。
- `:engine` 侧 `AdmissionProbe`：复用 `GenieSession` 做 load + 微生成（硬超时），复用 `EngineService` benchChunks/停滞看门狗作判据。
- 新增 AIDL `probeBackend(...)`（或复用 generate + `max_tokens=1` + timeout）。
- 画像存 `.admission.json`，由 `OnDeviceAssetManager` 管理（复用指纹失效）。
- Dart 路由 `on_device_capability.dart` / `HybridCloudEngine` 读画像选后端或直云。

---
status: active
updated: 2026-11-08
---

# 端侧驻留策略用户面（residency-strategy-ui）

> on-device-residency P1 用户面落地（L1 策略）：把「长驻行为」从固定环境矩阵开放为用户三档可选。上游事实源：`on-device-residency.md`（TTL 矩阵/双模/夜间批处理立法）与 `on-device-capability.md`（端侧能力总设计）——本文只承载「用户可选档位」这一层，不复制上游正文。

## 一、档位语义与定音

用户在设置页「端侧模型配置」段选择端侧模型的驻留策略（2026-11-08 拍板 = 三档预设，否决原始 TTL 自定义与消费双模用户面，见决策日志）：

| 档位 | 语义 | 映射（引擎侧） |
|---|---|---|
| 智能跟随（默认） | 不下发任何值，环境矩阵原样（低电归零 / 压力让位 / 灭屏 1min / 充电 30min / external 1min / 缺省 5min） | `Strategy.smart`，零行为变化 |
| 驻留更久 | 宿主主体保底充电档 30min（灭屏 1min 亦抬升至 30min）；**external 搭便车档不放大**（R7 拍板：外部请求无法把模型钉死在内存） | `maxOf(base, CHARGING_TTL_MS)` |
| 快速释放 | 全环境上限灭屏档 1min（充电 30min / 前台 5min 均压缩至 1min） | `minOf(base, SCREEN_OFF_TTL_MS)` |

红线（全档保留，任何档位不可旁路）：

- **低电(≤20%) / 省电模式 / TRIM 压力归零短路**在档位调整之前（R8 安全阀）。
- 5min 拍板缺省不翻：smart = 缺省档，偏离矩阵是显式用户 opt-in。
- 消费双模（`allow_deferred`）不在本档位面——M3 存量零变化语义未动。

## 二、TTL 优先级链（引擎侧裁决）

显式 TTL 注入（P0 诊断缝：dart-define / `on_device.residency_ttl_ms`）> 用户档位（P1 用户面）> `ResidencyPolicy` 矩阵。诊断缝仅诊断构建使用；两者同时存在时诊断缝胜出。观测对齐：`[RESIDENCY] policy` 日志行带 `strategy=` 字段；驱逐原因串与实际计时同源（scheduleTtl 每次回写 `lifecycle.ttlMs`——TTL 双源禁，矩阵缺省路径此前恒显 5min 旧值已修）。

## 三、生效路径

1. 设置页切档 → `OnDeviceAdmin.setResidencyStrategy` → SharedPreferences `on_device.residency_strategy` 落盘（UI 反馈只等这一步）。
2. **bind 重放 = unawaited 后件**：`sharedOnDeviceEngine.warmup()`（bind+waitReady，不触权重装载——懒加载立法不受影响）触发原生 `bind` 处理器刷新档位字段；已连接时就地重跑 `initEngine`（幂等，监听器缓存复用）即席生效；未连接随下次握手生效。重放自身 DEGRADE 留痕，**通道挂起/失败不拖设置面 UI**（单测实证教训：await 会把切档反馈与通道往返耦合死锁）。
3. `initEngine` 两键（TTL / 档位）均**无条件回填（缺键 = 复位缺省）**——切回智能跟随必须能退回矩阵，禁旧值跨重放残留。

## 四、落点

| 层 | 落点 |
|---|---|
| Kotlin 策略单源 | `android/app/src/main/kotlin/com/zzh/goodhub/engine/ResidencyPolicy.kt`（`Strategy` 枚举 + `strategyFrom` + `ttlMs` 档位参数）；`engine/EngineLifecycle.kt`（`KEY_RESIDENCY_STRATEGY`）；`EngineService.kt`（initEngine 无条件回填 + scheduleTtl 档位）；`EngineServiceBridge.kt`（bind 刷新 + 已连接重放 + `residencyInitConfig` Bundle 单源） |
| Dart 策略位 | `lib/llm/on_device_residency_policy.dart`（`OnDeviceResidencyStrategy` + 白名单读写 + `residencyBindArgs` 键组装单源 + label/description）；`lib/llm/on_device_engine_binding.dart`（bind 参数组装） |
| 门面 | `lib/coordinator/on_device_admin.dart`（ui→llm 收敛出口，写档 + unawaited 重放） |
| UI | `lib/ui/sections/on_device_config_section.dart`（「端侧驻留策略」下拉块；同轮把夜间批处理开关移出电池白名单误嵌套，恒显） |
| 测试 | `test/llm/on_device_residency_policy_test.dart`（缺省钉子/读写回路/白名单回落/键组装）；`test/ui/on_device_residency_strategy_test.dart`（渲染/切档联动/夜间开关恒显钉）；`android/app/src/test/kotlin/com/zzh/goodhub/engine/ResidencyPolicyTest.kt`（三档矩阵 + 安全阀全档保留） |

## 五、真机冒烟锚（已自动化 · 2026-11-08 首验通过）

驱动位 = debug 动作 `set_residency_strategy`（切档 + 回读校验，重放即席生效）+ `query_on_device`（强制端侧生成 → scheduleTtl 打 policy 行）；断言 = logcat `[RESIDENCY]` 行。可复跑序列（`toolbox run debug-bridge --device <SERIAL> ...`）：

1. `action set_residency_strategy '{"strategy":"extended"}'` → `action query_on_device '{"modelDir":"qwen3-5-2b-q4-0","prompt":"只回复两个字：收到","maxTokens":8}'` → `wait_log 'RESIDENCY.*strategy=extended.*ttl=1800000'`
2. 同法 frugal → `strategy=frugal.*ttl=60000`；随后 `wait_log 'RESIDENCY.*evict reason=ttl-elapsed'`（90s 窗）见实际驱逐（**正则免括号**——括号经多层 shell 传递会被剥成 ERE 分组）。
3. 同法 smart → `strategy=smart.*ttl=<矩阵值>`（充电 1800000 / 常规 300000 / 灭屏 60000 / 低电 0）。
4. 三档连续即席生效本身即 bind 重放 + initEngine 无条件回填复位断言（引擎 strategy 字段无残留）。
5. 缺省（从未选档）路径行为与历史版本逐字节一致（smart 不出键，单测钉）。

## 决策日志

> devlog 决策/权衡类条目归档专节（dev-loop §4；机械件 `toolbox run dlog <epic>` 追加）。

- [2026-11-08] 档位语义拍板 = 三档驻留预设（smart/extended/frugal），在引擎侧 `ResidencyPolicy` 加模式参数承载（否决: 原始 TTL 分钟档直选——显式注入整体旁路矩阵含低电归零安全阀；消费双模用户面——须跨仓修订 `allow_deferred` 缺省语义（M3），改动面过重）
- [2026-11-08] 设置切档完成性只等偏好落盘，bind 重放为 unawaited 后件（否决: await warmup 后再反馈——bind 通道往返被耦合进设置面，测试实证通道挂起即死锁 UI）

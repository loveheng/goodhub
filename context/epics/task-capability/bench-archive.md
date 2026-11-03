---
memo: bench-archive
format: v1
epic: task-capability
---

# 端侧适用性对照表 · 真机采集归档（W2 · S11）

> 数据面 = `lib/llm/on_device_bench.dart` 任务套件扫描（`--dart-define=ON_DEVICE_BENCH=true --dart-define=ON_DEVICE_BENCH_TASK_SUITE=true`）；用例集与机械质量判据 = `lib/llm/on_device_bench_suite.dart`；采集行契约与归档渲染 = `lib/llm/on_device_bench_archive.dart`。
> 消费面 = S12（`assets/model-specs.json` 的 bundle 任务亲和性字段 + `on_device_asset_manager.dart` 加载器）。
> 原始行落设备侧应用外部目录（adb 可 pull，不依赖 root / run-as）：`/sdcard/Android/data/com.zzh.goodhub/files/bench/rows.jsonl` 与同目录 `archive.md`。

## 采集场次

| 项 | 值 |
|---|---|
| 真机 | OnePlus PLQ110（Ace 6 / sun / Snapdragon 8 Elite） |
| 资产 | `gemma3-1b-it-int4-litertlm`（ctx 1280，`.litertlm` 族，Runner = LiteRtLmRunner） |
| 段 | `pass=auto`（Runner 自裁）／`pass=gpu`（backendHint 强制 GPU 档）——**段名按可控维度命名**，不叫 NPU 段（Dart 侧读不到后端画像，见「取证缺口」） |
| 采样 | T1.0 / topP 0.95（模型推荐档，meta `recommendedSampling`；低温窄分布会触发 gemma3 复读环，低温测出的质量档是采样伪影） |
| 用例 | 9 例 = 8 个任务类型 × 2 体量档（短档输入 24~69 字 / 长档输入 925~1016 字） |
| 采集时间 | 2026-11-03 15:41（15:41 与 16:08 两轮独立采样，质量档结论 **18/18 完全一致**——机械判据可复现性实证） |

## 对照表（逐用例）

| 段 | 任务类型 | 用例 | 体量档 | 输入字数 | TTFT(ms) | TPOT(ms) | tok/s | 产出字数 | 质量档 | 命中率 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pass=auto | qa | qa-short | short | 24 | 2328 | 16.0 | 62.4 | 65 | pass | 1.0 | facts 2/2 |
| pass=auto | classify | classify-short | short | 55 | 1300 | 10.5 | 95.5 | 3 | fail | 0.0 | label miss |
| pass=auto | extract | extract-short | short | 69 | 502 | 16.7 | 60.0 | 69 | degraded | 0.7 | fields 2/3 |
| pass=auto | rewrite | rewrite-short | short | 61 | 485 | 18.5 | 53.9 | 41 | pass | 1.0 | facts 2/2 |
| pass=auto | code | code-short | short | 27 | 314 | 8.2 | 122.3 | 206 | pass | 1.0 | facts 4/4 |
| pass=auto | multiTurn | multiTurn-short | short | 32 | 487 | 18.3 | 54.5 | 10 | fail | 0.0 | facts 0/2 |
| pass=auto | qa | qa-long | long | 925 | 7552 | 16.3 | 61.5 | 182 | degraded | 1.0 | facts 2/2 +冗长(181>120) |
| pass=auto | summarize | summarize-long | long | 1012 | 6787 | 21.6 | 46.2 | 82 | pass | 1.0 | facts 3/3 |
| pass=auto | longDocQa | longDocQa-long | long | 1016 | 6781 | 18.6 | 53.9 | 50 | pass | 1.0 | facts 2/2 |
| pass=gpu | qa | qa-short | short | 24 | 397 | 9.3 | 107.0 | 51 | pass | 1.0 | facts 2/2 |
| pass=gpu | classify | classify-short | short | 55 | 137 | 1.0 | 952.8 | 2 | fail | 0.0 | label miss |
| pass=gpu | extract | extract-short | short | 69 | 156 | 10.6 | 94.2 | 70 | degraded | 0.7 | fields 2/3 |
| pass=gpu | rewrite | rewrite-short | short | 61 | 138 | 12.0 | 83.5 | 199 | degraded | 1.0 | facts 2/2 +冗长(199>60) |
| pass=gpu | code | code-short | short | 27 | 145 | 6.2 | 160.2 | 226 | pass | 1.0 | facts 4/4 |
| pass=gpu | multiTurn | multiTurn-short | short | 32 | 141 | 12.3 | 81.2 | 194 | degraded | 0.5 | facts 1/2 |
| pass=gpu | qa | qa-long | long | 925 | 504 | 10.2 | 97.7 | 173 | degraded | 1.0 | facts 2/2 +冗长(172>120) |
| pass=gpu | summarize | summarize-long | long | 1012 | 485 | 14.5 | 69.1 | 79 | pass | 1.0 | facts 3/3 |
| pass=gpu | longDocQa | longDocQa-long | long | 1016 | 488 | 12.5 | 79.8 | 24 | pass | 1.0 | facts 2/2 |

## 分段汇总（段 × 任务类型）

| 段 | 任务类型 | 用例数 | 合格 | 降级 | 不可用 | TTFT 区间(ms) | tok/s 区间 | 适用档位 |
|---|---|---|---|---|---|---|---|---|
| pass=auto | qa | 2 | 1 | 1 | 0 | 2328~7552 | 61.5~62.4 | 降级可用 |
| pass=auto | classify | 1 | 0 | 0 | 1 | 1300 | 95.5 | 不可用 |
| pass=auto | extract | 1 | 0 | 1 | 0 | 502 | 60.0 | 降级可用 |
| pass=auto | rewrite | 1 | 1 | 0 | 0 | 485 | 53.9 | 可用 |
| pass=auto | code | 1 | 1 | 0 | 0 | 314 | 122.3 | 可用 |
| pass=auto | multiTurn | 1 | 0 | 0 | 1 | 487 | 54.5 | 不可用 |
| pass=auto | summarize | 1 | 1 | 0 | 0 | 6787 | 46.2 | 可用 |
| pass=auto | longDocQa | 1 | 1 | 0 | 0 | 6781 | 53.9 | 可用 |
| pass=gpu | qa | 2 | 1 | 1 | 0 | 397~504 | 97.7~107.0 | 降级可用 |
| pass=gpu | classify | 1 | 0 | 0 | 1 | 137 | 952.8 | 不可用 |
| pass=gpu | extract | 1 | 0 | 1 | 0 | 156 | 94.2 | 降级可用 |
| pass=gpu | rewrite | 1 | 0 | 1 | 0 | 138 | 83.5 | 降级可用 |
| pass=gpu | code | 1 | 1 | 0 | 0 | 145 | 160.2 | 可用 |
| pass=gpu | multiTurn | 1 | 0 | 1 | 0 | 141 | 81.2 | 降级可用 |
| pass=gpu | summarize | 1 | 1 | 0 | 0 | 485 | 69.1 | 可用 |
| pass=gpu | longDocQa | 1 | 1 | 0 | 0 | 488 | 79.8 | 可用 |

## 任务类型总览（跨段 · 适用档位）

| 任务类型 | 用例数 | 合格 | 降级 | 不可用 | 适用档位 |
|---|---|---|---|---|---|
| qa | 4 | 2 | 2 | 0 | 降级可用 |
| classify | 2 | 0 | 0 | 2 | 不可用 |
| extract | 2 | 0 | 2 | 0 | 降级可用 |
| rewrite | 2 | 1 | 1 | 0 | 降级可用 |
| code | 2 | 2 | 0 | 0 | 可用 |
| multiTurn | 2 | 0 | 1 | 1 | 部分不可用 |
| summarize | 2 | 2 | 0 | 0 | 可用 |
| longDocQa | 2 | 2 | 0 | 0 | 可用 |

## 结论（机械判据 + 实测代价）

1. **两类任务在 1B 端侧模型上不可用**——`classify` 两段均 label miss（把「充电时烫得厉害」判成「电池」）；`multiTurn` 在 auto 段答非所问（「您，您负责哪个城市？」），gpu 段只命中 1/2 事实。→ S12 的任务亲和性字段不得给这两类挂「可用」档。
2. **结构化抽取止步降级档**——`extract` 的 JSON 可解析但字段错（date 写成「12月12日」、name 写成「林工计划」）→ 端侧在**无约束解码**下的结构化产出不可信，直接支撑 D4 前提（S17b 约束解码承载必补）与 K15（结构化场景禁截断降级档）。
3. **体量是主要成本项，且段间差一个数量级**——长体量（≈1K 字输入）下 auto 段 TTFT ≈6.8~7.6s、gpu 段 ≈0.49~0.50s（≈14×）；短体量下两段同量级（auto 0.3~2.3s / gpu 0.14~0.40s）。→ 时效判定（S14b）的时长口径必须区分「首例冷启」与「稳态」：auto 段首例 2328ms vs 稳态 314~502ms。
4. **auto 段与既有三档归档不一致**——既有归档记 NPU 档 TTFT 102~142ms，本轮 auto 段表现更接近归档里的「generic 陷阱档」（长体量 TTFT 秒级）。**本轮无法判定 auto 段实际落在哪个后端**（见取证缺口）——段名保留为「自裁」，不得改写成 NPU 实测。
5. **tok/s 在极短产出上不可比**——classify 产出 2~3 字时 gpu 段 tok/s 报到 952.8（chunk 数过少，分母塌缩）→ 归档表内 tok/s 仅在产出 ≥ 50 字时可比。
6. **机械判据的已知盲区**——`code` 判据只查结构令牌（fun / reverse / String / 括号），不查语义正确性：实测产出的 `reverseString()` 实现本身有编译级错误（不可变 val 重复赋值）仍判「合格」。→ S12 落档时该类须标注「结构合格 ≠ 语义可用」，不得据此给代码类挂高适用档。
7. **判据可复现性已实证**——15:41 与 16:08 两轮独立采样（同一资产、同一用例集、同一采样档）给出的质量档结论 **18/18 完全一致**；延迟与吞吐有采样抖动（首例冷启尤其明显），故**档位结论以质量档为准、代价数字按量级读**。

## 取证缺口（本轮未覆盖）

- **auto 段后端身份未取证**：`:engine` 未向 Dart 透出 `activeRuntime`，无法区分 NPU / GPU / generic（本轮 `runner dispatch: GenieSession -> LiteRtLmRunner` 只证明 Runner 族）。→ 需后端画像透出（归 on-device epic 的后端画像议题）。
- **内存 / 发热未采**：`:engine` PSS 与机身温度须 adb 侧外部采样（`dumpsys meminfo` + thermalservice），本轮未采（对照表口径不含这两项）。
- **窗口边界未采**：ctx=1280 资产上「超窗拒绝」路径未触发（长体量输入 ≈1K 字 < 窗口）。
- **NPU 专用 bundle 未采**：设备装的是通用 `.litertlm` bundle（sm8750 NPU 专用 bundle 未装），故无 NPU 档数据。
- **无第三方交叉评判**：质量判据为机械判据，同一用例的云端产出质量未采（无对照基准）。

## 复采步骤（人工场次 runbook）

```bash
export PATH="$HOME/flutter/bin:$HOME/android-sdk/platform-tools:$PATH" ANDROID_HOME="$HOME/android-sdk"

# 1) 构建（诊断面 dart-define；正式交付构建不带这两个开关）
flutter build apk --debug --dart-define=ON_DEVICE_BENCH=true \
  --dart-define=ON_DEVICE_BENCH_TASK_SUITE=true

# 2) 覆盖安装（debug 签名一致 → 设备上的模型资产保留；签名不一致会失败，
#    此时模型资产丢失、bench 报「no registered model, skip」）
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# 3) 启动 + 取数（装载 + 两段扫描：自裁段 → disable → 强制 GPU 段）
adb shell am force-stop com.zzh.goodhub && adb logcat -c
adb shell am start -n com.zzh.goodhub/.MainActivity
sleep 90
adb pull /sdcard/Android/data/com.zzh.goodhub/files/bench ./bench-archive
adb logcat -d > bench-logcat.txt   # 段归因与 :engine 侧对照（runner dispatch 等）
```

> 取数纪律：归档表以设备侧 `files/bench/archive.md` 为准（应用自渲染，键集固定）；
> logcat 中的 `[on-device-bench] TASK {...}` 为原始行（JSONL），`TASKOUT {...}` 为
> 原始产出（人工目视复核用，截断 400 字）。

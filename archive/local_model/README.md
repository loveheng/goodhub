# archive/local_model —— 端侧模型管理链（已归档，待复活）

**归档日期**：2026-10-15 ｜ **裁决**：SA-Q3（端侧模型管理链处置 = 归档，现阶段不补接线）
**原因**：端侧推理推迟的拍板未翻转（architecture §16 门槛校准待定），该三件自落地起零接线、零测试，使 F2.3/N5「端侧模型按需下载」实为未交付；留在 `lib/` 会虚增行数、稀释覆盖率并持续制造「文档说有、代码没接」的脱节。

## 内容

| 文件 | 说明 |
|---|---|
| `llm_model_manager.dart` | 模型目录/下载/落盘/选型管理（24KB，核心件） |
| `llm_download_isolate.dart` | 下载 isolate 通道（被 manager 引用） |
| `remote_config_store.dart` | 远端模型清单缓存（被 manager 引用） |

## 复活条件（任一触发即重开）

1. architecture §16 端侧门槛校准拍板（Q8/INT4 包定案）且端侧引擎重新纳入排期；
2. 出现明确的「端侧模型按需下载」真实需求（F2.3/N5 解冻）。

## 复活步骤

1. `git mv archive/local_model/<三件> lib/llm/`；
2. `llm_model_manager.dart` 顶部两处跨目录 import 改回同级：
   `import '../../lib/llm/llm.dart';` → `import 'llm.dart';`、
   `import '../../lib/llm/llm_model.dart';` → `import 'llm_model.dart';`；
3. 删除 `analysis_options.yaml` 的 `- archive/**` exclude 行（若本目录已空则整目录删除）；
4. 接线：下载 UI 入口 + 引擎预热装配（`lib/llm/llm.dart`）；
5. 补单测（下载进度/断点续传/清单解析）——**未补测即未复活**。

> `lib/llm/llm_model.dart` **不在本归档内**：它被生产代码 `lib/llm/llm.dart:5` 引用（`llmModelVisibleOnDevice`），属活代码。

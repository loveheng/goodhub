---
description: goodhub（AI 宿主 App，Flutter/MCP 客户端）工作流事实源：构建/测试命令、模块结构、环境硬约束、与 goodshare 的 MCP 接缝。构建报错、跑测试、换机器前先读，命令勿凭记忆写。
---

# goodhub · AI 宿主 App 工作流事实源

> 项目一句话：**goodhub**——AI 宿主 App（master / 交互式 MCP 客户端），认领 goodshare 的远程 AI 任务（claim→推理→apply）。接缝契约 SSOT = goodshare 仓 `docs/design/ai-app-split.md`（跨仓只读引用，本仓不复制正文）。

## 技术栈（拍板 2026-10-10）

- **Flutter**（与 goodshare 同族，Android 首发）：宿主自有 UI（聊天/决策卡片）、自有引擎（端侧 LiteRT-LM + 云端 LLM）、自有持久数据
- MCP 客户端连 goodshare 内嵌 server：`http://<手机IP>:8765/mcp`（Streamable HTTP，无状态逐请求 JSON-RPC）
- 当前阶段 = **M1 最小壳**（MCP 连接 → claim → 推理 → apply 闭环），产品化（M3+）不在本阶段

## 模块结构（M1 最小壳，随实现更新本表）

> 工程编码基准规则（分层拓扑/硬规则/质量门禁）：`docs/project/coding-standards.md`（SSOT）。M1 最小壳简化结构与该规范的目标拓扑按里程碑演进收敛。

```
lib/
  mcp/        # MCP 客户端：JSON-RPC over Streamable HTTP、claim/touch/apply 封装
  llm/        # 引擎层：端侧 LiteRT-LM（M2 随迁 LlmBridge.kt + proguard keep）+ 云端 LLM
  ui/         # 最小壳 UI（闭环验证用）
android/      # LlmBridge.kt、模型文件管理（M2 随迁）
```

## 常用命令（每条命令显式 export PATH/ANDROID_HOME）

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter pub get                 # 依赖
flutter analyze                 # 静态检查 → 0 issue 为交付线
flutter test --timeout 60s      # 单测 → 全过为交付线（⚠️ 务必带 --timeout，widget 测试默认 10 分钟）
flutter build apk --debug       # 构建
```

> ✅ 命令实测状态：2026-10-10 工程骨架落地后已实测——`pub get` / `analyze`（0 issue）/ `test`（全过）均跑通；`build apk --debug` 尚未实测（M1 闭环时验证）。

## 环境硬约束

- Flutter 在 `~/flutter`（tarball 安装，不在 PATH），Android SDK 在 `~/android-sdk`；模拟器不可用，UI 验证只能真机侧载
- goodshare MCP 测试走局域网直连 `http://<手机IP>:8765/mcp`（本机沙箱 adb reverse 无法绑定端口）
- LiteRT-LM 迁移教训：proguard 必须 keep `-keep class com.google.ai.edge.** { *; }`（R8 混淆致 JNI SIGABRT）

## MCP 接缝速查（细节以契约文档为准）

| 工具 | 时机 | 要点 |
|---|---|---|
| `claim_ai_task` | 空闲循环 | 返回 `{task_id, item_id, task_action, text, ...}` 或 `{status:"idle"}`；纯文本载荷无附件 |
| `touch_ai_task` | 每 5s（含模型加载期） | 30s 无心跳任务被回收重认领 |
| `apply_ai_result` | 推理完成 | 带 `expected_version` 乐观锁；冲突重读重试或放弃 |

正文不预截断：goodshare 给全文，宿主按引擎 ctx 自行截断（自有降级 + note）。

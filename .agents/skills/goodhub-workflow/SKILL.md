---
description: goodhub（AI 宿主 App，Flutter/MCP 客户端）工作流事实源：构建/测试命令、模块结构、环境硬约束、与 goodshare 的 MCP 接缝。构建报错、跑测试、换机器前先读，命令勿凭记忆写。
---

# goodhub · AI 宿主 App 工作流事实源

> 项目一句话：**goodhub**——AI 宿主 App（master / 交互式 MCP 客户端），认领 goodshare 的远程 AI 任务（claim→推理→apply）。接缝契约 SSOT = goodshare 仓 `docs/design/ai-app-split.md`（跨仓只读引用，本仓不复制正文）。

## 技术栈（拍板 2026-10-10）

- **Flutter**（与 goodshare 同族，Android 首发）：宿主自有 UI（聊天/决策卡片）、自有引擎（端侧 LiteRT-LM + 云端 LLM）、自有持久数据
- MCP 客户端连 goodshare 内嵌 server：`http://<手机IP>:8765/mcp`（Streamable HTTP，无状态逐请求 JSON-RPC）
- **当前阶段 = M4+（双角色）**：Client 侧（多 Server 挂载 + ToolRouter 前缀隔离 + JIT 发现 + 双轨消息流 UI + 记忆沙盒 + 会话持久化）与 **Server/Gateway 侧**（`:8766/mcp` 聚合网关：本地 Binder 插件 + 远端 HTTP 全量聚合，对 PC 单入口）均已落地；自更新（R2 整包）已首发。**M4 剩余**：T4 连接韧性（暂缓中，见 `docs/design/m4.md`）、T6 零散余项。

## 模块结构（M4+ 扁平域目录，随实现更新本表）

> 工程编码基准规则（分层拓扑/硬规则/质量门禁）：`docs/project/coding-standards.md`（SSOT §1）。**现状 = 扁平域目录**（M4-D4 拍板：不加 `features/` 前缀，目标拓扑随后续里程碑统一收敛）——新增文件沿用现状，禁止单独引入双拓扑。域内文件清单查 `goodhub-index` skill。

```
lib/
  main.dart    # 装配入口：引擎预热 / 记忆清扫 / $ref 启动清池 / 首页挂载（ChatPage）
  mcp/         # MCP 客户端域：json_rpc、mcp_client（HTTP + Binder）、transport/、
               #   server_endpoints（多端点+密钥）、server_probe（探活）、
               #   local_plugin_discovery（同机插件发现）、trusted_plugins、sampling
  llm/         # 引擎域：端侧 ChannelLlmEngine（android LlmBridge.kt）+ cloud/（BYOK
               #   双协议 + SSE 解析）。（端侧模型管理链已归档 archive/local_model/）
  coordinator/ # 编排域：agent_loop、tool_router（前缀隔离）、discovery_executor（JIT
               #   元工具）、permission_gateway（L1/L2）、pii_fence（N7 围栏）、
               #   tool_breaker（熔断+步数墙）、context_governor、ref_store（$ref）、
               #   mcp_tool_face、memory_tool_executor
  sandbox/     # 记忆沙盒域：memory_store（memory.md/lessons.md/ops.log）、conversation_store
  gateway/     # 聚合网关域（Server 角色，2026-10-12 解冻）：gateway_server（Streamable
               #   HTTP/SSE）、mcp_gateway_handler（聚合分发）、gateway_controller（装配）、
               #   gateway_security（入站安全闭环）、gateway_backpressure、
               #   gateway_loop_guard（环路防护）、gateway_service_channel（原生桥）
  ui/          # UI 域：chat_page（首页）、services_hall_page、memory_board_page、
               #   update_page、components/（双轨流/卡片/流式渲染）、tokens/
  core/        # 基础设施：storage/sequential_file_writer、security/（SecureKeyValue）、
               #   tokens、errors
  task/        # 任务循环域（M1 骨架，现为 debug 入口）
  update/      # 自更新域：manifest / service / installer
android/       # LlmBridge.kt、GatewayForegroundService、Binder 服务、plugin-core SDK
archive/       # 待复活资产（当前：local_model/）——已被 analysis_options 排除
```

## 常用命令（每条命令显式 export PATH/ANDROID_HOME）

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter pub get                 # 依赖
flutter analyze                 # 静态检查 → 0 issue 为交付线
flutter test --timeout 60s      # 单测 → 全过为交付线（⚠️ 务必带 --timeout，widget 测试默认 10 分钟）
flutter build apk --debug       # 构建
```

> ✅ 命令实测状态（2026-10-15 更新）：`pub get` / `analyze` / `test --timeout 120s` 均跑通——**analyze 仅剩 1 条存量 info**（`lib/ui/gateway_loop_debug_page.dart:670` `value` deprecated，Flutter 3.33 弃用，非阻断）；**测试 491 例全绿**（2026-10-15 B3 补测后；网关/自更新/端侧引擎/chat_page 冒烟均已入网）。构建已实测：`release-r2.sh` 出包并推 R2（v1.0.1+2003，42.7MB），`flutter build apk` 通道可用；真机侧载/ADB 联调为唯一 UI 验证路径（无模拟器）。

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

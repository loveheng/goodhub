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
               #   connection_manager（健康/韧性连接池）、
               #   local_plugin_discovery（同机插件发现）、trusted_plugins、sampling
  app/         # 装配容器域：service_directory（ServerEndpointStore 单入口 seed，
               #   目标拓扑唯一先行 seed，禁止在此之外新增前缀）
  llm/         # 引擎域：端侧 ChannelLlmEngine（android LlmBridge.kt）+ cloud/（BYOK
               #   双协议 + SSE 解析 + sampling_engine（云 SamplingEngine 适配）+
               #   chat_message_codec（transcript 编解码，自 sandbox 迁出））。
               #   （端侧模型管理链已归档 archive/local_model/）
  coordinator/ # 编排域：agent_loop、tool_router（前缀隔离）、discovery_executor（JIT
               #   元工具）、permission_gateway（L1/L2）、pii_fence（N7 围栏）、
               #   tool_breaker（熔断+步数墙）、context_governor、ref_store（$ref）、
               #   mcp_tool_face、memory_tool_executor、memory_kernel、
               #   conversation_archive、mcp_runtime（McpRuntime 装配核 + ConversationSession，
               #   MCP 侧 Run 级装配唯一入口）、hybrid_assembly（云端引擎装配）
  sandbox/     # 记忆沙盒域：memory_store（memory.md/lessons.md/ops.log）、
               #   conversation_store（纯 JSON + core DTO；编解码已迁 llm/cloud，禁回流）
  gateway/     # 聚合网关域（Server 角色，2026-10-12 解冻）：gateway_server（Streamable
               #   HTTP/SSE）、mcp_gateway_handler（聚合分发）、gateway_controller（装配）、
               #   gateway_security（入站安全闭环）、gateway_backpressure、
               #   gateway_loop_guard（环路防护）、gateway_service_channel（原生桥）
  ui/          # UI 域：chat_page（首页）、settings_page、memory_board_page、
               #   update_page、gateway_loop_debug_page（网关联调/spike）、
               #   claim_loop_page、grammar_spike_page、navigator_key
               #   （appNavigatorKey 后台弹层入口：网关 L2 卡）、
               #   gateway_consent_dialog（DialogGateDelegate：网关 L2 远程确认卡）
               #   error_copy、components/（双轨流/卡片/流式渲染）、tokens/
  core/        # 基础设施：storage/sequential_file_writer、security/（SecureKeyValue）、
               #   tokens、errors（cloud_llm_error/inference_error/mcp_error）、
               #   audit_sink（审计端口）、chat_message_data/tool_result（跨域 DTO）、
               #   network/backoff（T4 退避底座）
  task/        # 任务循环域（M1 骨架，现为 debug 入口）
  update/      # 自更新域：manifest / service / installer
android/       # LlmBridge.kt、GatewayForegroundService、Binder 服务、plugin-core SDK
archive/       # 待复活资产（当前：local_model/）——已被 analysis_options 排除
```

## 架构依赖纪律与修复施工规范（2026-10-16 盘点立 · 同轮存量清零）

> 规则 SSOT 链：设计 `docs/design/window-kernel-split.md` §5 四条铁律 → 编码基准 `docs/project/coding-standards.md` §1.1（五条判据）。**本节登记依赖红灯 + 防复发纪律 + 施工记录**，规则正文一律查上游，不复制（防双源漂移）。

### 依赖方向（红灯清单）

| 方向 | 判定 |
|---|---|
| 窗口（`ui/` + headless `gateway_controller`）→ 内核 | ✅ 允许：读快照 + 端口，禁持领域态 |
| `core` ← 任何域 | ✅ `core` 零出向，叶层不得反向 |
| `mcp` / `sandbox` → `coordinator` | ✅ 已清零（arch-hardening ②，2026-10-16）：face 经 `mcp/connection_face.dart` 注入，`ToolExecutionResult` 下沉 `core/tool_result.dart`，opsLog 走 `core/audit_sink.dart` 端口；**新增此类 import = 违例** |
| `gateway` → `ui` | ✅ 已清零（arch-hardening ①，2026-10-16）：Flutter 弹层迁 `ui/gateway_consent_dialog.dart`，gateway 域只留 `GateDelegate` 接口 + fail-closed（桥缺位恒拒 `headless_no_ui_prompt`）；**新增此类 import = 违例** |
| `mcp` / `sandbox` → `llm` | ✅ 已清零（arch-hardening ③/④，2026-10-16）：sampling 走 `SamplingEngine` 端口（core 消息货币 `ChatMessageData`，云适配 `llm/cloud/sampling_engine.dart`）；transcript codec 迁 `llm/cloud/chat_message_codec.dart`，存储层只认 JSON Map + core DTO；**新增此类 import = 违例** |

**施工红线**：修复期禁止新增任何反向边；上表存量违例已于 2026-10-16（arch-hardening epic）清零——此后任何命中上表的 import 即为新违例，改相关代码前先查 `goodhub-index` 索引行。

### 共享态与装配纪律（存量已清零 · 两项禁令保留）

- ~~服务目录禁三拼~~ → ✅ **已修（arch-hardening 步 0）**：唯一 owner = `lib/app/service_directory.dart` 单入口，gateway 漏 prefs 迁移活 bug 已修。**禁令保留**：新消费点一律取装配容器单例，禁止就地拼路径。
- **会话级态禁挂全局单例（#7 已收口）**：`GatewayController.shared` 的 `_hostDefaultPrivateServerId` 已澄清为 **host-level 默认投影源**（新连接 `forSession()` 复制），非会话态；per-connection 投影隔离已在 `McpGatewayServer._handlers` 落地并测试（阶段二 D-D）。**禁令保留**：禁止在 shared 上加新会话级字段；`workspaceId` 投影平面接线见 `goodhub-index` 债 #11（待 chatmessage 记忆分区）。
- **双 ToolRouter 边界**：生产路由只引 `lib/coordinator/tool_router.dart`；`lib/mcp/tool_router.dart` = F1.9 海关过滤唯一实现，SA-Q6 拍板「保留待接线」——**不删、不引**，防同名误导入。
- ~~装配下沉方向~~ → ✅ **已完成（步 1/2）**：MCP 侧 Run 级装配唯一入口 = `lib/coordinator/mcp_runtime.dart`（`assemble/close` + `clientFactory` 注入位）；chat / gateway_controller / gateway_loop_debug_page / task_loop 四调用点已收敛。**禁令保留**：窗口层禁止再内联建 client/face/router。
- **联调/spike 页不算生产路径**：可简化，但不得复制装配胶水（复用挂载原语 + 经 `clientFactory` 注入 fake 传输）——步 2 已按此收敛，保持。

### 施工验收（联动 coding-standards §6.1）

- 每收敛一个调用点：补**装配产物等价性**单测 + **资源释放**断言（经注入 fake client 计数），不得只靠真机冒烟；
- 当前基线（2026-10-16 arch-hardening 收官记录）：`flutter analyze` 0 issue；`flutter test --timeout 180s` **707/707 全绿**（#7 修复后全仓无回归，含新增 idle GC 回归 1 例；原存量 `memory_kernel_test`×2 flaky 已修：固定延迟猜等 → 写链确定性排空，见 lib 三件 `settled`/`ioDrained` API）；
- 修复推进顺序与端口契约以 `docs/design/arch-hardening.md`（施工态勾稽）+ window-kernel-split §7.5（内容 SSOT）为准，本表只做入口摘要。

## 常用命令（每条命令显式 export PATH/ANDROID_HOME）

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter pub get                 # 依赖
flutter analyze                 # 静态检查 → 0 issue 为交付线
flutter test --timeout 60s      # 单测 → 全过为交付线（⚠️ 务必带 --timeout，widget 测试默认 10 分钟）
flutter build apk --debug       # 构建
```

> ✅ 命令实测状态（2026-10-16 更新）：`pub get` / `analyze` / `test --timeout 180s` 均跑通——**analyze 0 issue**（存量 1 info `gateway_loop_debug_page.dart:670` `value` deprecated 已清）；**测试 706/706 全绿**（2026-10-16 arch-hardening：原存量 `memory_kernel_test`×2 flaky 已修，写链确定性排空 API 见 lib）。构建已实测：`release-r2.sh` 出包并推 R2（v1.0.1+2003，42.7MB）；真机侧载/ADB 联调为唯一 UI 验证路径（无模拟器）。

## 环境硬约束

- Flutter 在 `~/flutter`（tarball 安装，不在 PATH），Android SDK 在 `~/android-sdk`；模拟器不可用，UI 验证只能真机侧载
- goodshare MCP 测试走局域网直连 `http://<手机IP>:8765/mcp`（本机沙箱 adb reverse 无法绑定端口）
- LiteRT-LM 迁移教训：proguard 必须 keep `-keep class com.google.ai.edge.** { *; }`（R8 混淆致 JNI SIGABRT）

## 工具链护栏（实测踩坑，勿重踩）

- **`toolbox run todos add` 的事项文本经 shell 传递，禁用反引号与 `$`**：反引号被 bash 当命令替换执行——实测 `` `coding-standards.md` §2 … `` 落盘后开头被吞，只剩 ` §2 …`；`$` 同样会被变量展开。**带这两种字符的条目改用 Edit 直接写文件**，不要走 shell（事后补回易漏且留双源）。
- **`--src` 必须以 `ai` 或 `用户` 起头**（可带 `, 说明` 后缀）：写 `agent` 被拒（exit 1，误以为落盘失败）。
- **域内 `todos.md` 机械件格式**：标题须为 `# <epic名> · 域内待办`、frontmatter 须 `format: v3` + `epic: <名>`；否则 `todos add` 报「缺标题行」拒绝写入（存量 v2 域文件首次写入前须先改头部）。

## MCP 接缝速查（细节以契约文档为准）

| 工具 | 时机 | 要点 |
|---|---|---|
| `claim_ai_task` | 空闲循环 | 返回 `{task_id, item_id, task_action, text, ...}` 或 `{status:"idle"}`；纯文本载荷无附件 |
| `touch_ai_task` | 每 5s（含模型加载期） | 30s 无心跳任务被回收重认领 |
| `apply_ai_result` | 推理完成 | 带 `expected_version` 乐观锁；冲突重读重试或放弃 |

正文不预截断：goodshare 给全文，宿主按引擎 ctx 自行截断（自有降级 + note）。

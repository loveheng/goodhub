---
status: active
updated: 2026-10-15
---

# 未来演进考量（Future Considerations）

> 七轮评审（2026-10-10）识别的 5 个扩展卡点：**当前架构满足 M1~M2.5，本文仅预埋演进锚点，禁止在 M1 阶段为未来过度重构**（solution-admission 口径）。对应架构规约 `docs/product/architecture.md`（ADR-001~004）。

## FC1 记忆沙盒的语义检索（RAG）演进

- **卡点**：纯文本三件套在记忆达数千条后污染上下文、小模型归纳丢早期细节；向量库迁移需重构 `query_memory`。
- **已留锚（现在做）**：`memory.md` 写入格式带结构化块标识——`<!-- id: mem_001, tags: [pref,ui], ts: <epoch> -->`，为免清洗迁移向量/元数据索引留解析锚点。
- **触发重构条件**：记忆条数 > 500 或上下文注入占比 > 30% 持续一周 → 引入 SQLite-vec/ObjectBox 语义检索。

## FC2 PII 围栏的多模态边界

- **卡点**：正则脱敏仅覆盖 UTF-8 文本；MCP 支持二进制 Resource（image/png、PDF、音频 base64），围栏对非文本失效。
- **已留锚（M1~M2 即生效）**：出站数据含非文本 MIME（`image/*`、`application/pdf`、音频）**默认禁止直塞云端 Prompt**；确需发送时强制 L2 确认卡片由用户放行（展示来源与类型，不放行原文）。
- **触发重构条件**：多模态模型接入（M3+）→ 评估端侧图像 PII 检测模型。

## FC3 跨端多节点（LAN Peer Mesh）的 Token 体系

- **卡点**：本机 Binder 自动握手与跨设备手动配对是两套割裂逻辑；Tailscale 组网/平板挂载场景配对繁琐。
- **已留锚（M1.5 实现 Token 时）**：Session Token 设计为**自包含 HMAC 签名票据**（含权限白名单 + TTL）——本机 Binder 通道与跨机 TLS/PSK 配对复用同一套校验与权限绑定逻辑，避免两个验证代码分支。
- **触发重构条件**：跨设备挂载需求真实出现（用户反馈或产品决策）。

## FC4 Sub-Agent 编排子网的环检测升级

- **卡点**：`hop_count ≤ 2` 静态硬限——桌面 AI 平台 B 若自身是微型 Agent，B 反调宿主 Sampling 时 hop=3 直接触发熔断，Sub-Agent 编排被卡死。
- **演进方向（M1 仍用 hop≤2，简单够用）**：升级为**调用链环检测**——请求头追加 `trace_chain: "goodshare->goodhub->todo"`（Visited Set 语义），深度上限放宽至 4，但链内同节点重复出现立即阻断。
- **触发重构条件**：出现第一个自身含 Agent 能力的桌面平台接入。

## FC5 Tool/Resource Schema 版本治理

- **卡点**：Server 热更新改工具入参类型（int→String）时，运行中长任务的全量目录刷新引发 Schema 漂移 → 反序列化崩溃。
- **演进方向**：契约注解 `x-mcp-schema-version: "1.0.0"`（SemVer）+ **会话生命周期内锁死 Schema 镜像快照**，跨版本变更仅新 Session 生效。
- **触发重构条件**：首个第三方 Server 发生热更新式工具变更，或 goodshare 引入热更新机制。
- **关联**：`x-mcp-schema-version` 已加入接缝契约扩展清单（goodshare ai-app-split.md）。

## FC6 反向能力（Server 端）交互形态：~~待完成队列~~ → **已触发，落地为实时聚合网关**（2026-10-12 翻转）

- **状态**：~~暂缓项（2026-10-10 用户裁决）~~ → **已触发并按 TC5~TC8 解冻落地（2026-10-12 拍板，G1~G5 于 2026-10-13 设备 e2e + PC 真机连调通过）**。
- **背景**：Server 角色（`:8766` 对外暴露特权工具）原列 M1.5，因「无真实接入场景、依赖与结构边界不清晰」被裁决暂缓不做（architecture.md 定位节注记）。
- **服务对象澄清（维持有效）**：Server 端对接的是**桌面 AI 平台（MCP 客户端，如 Claude Desktop / Cursor / ZCode）**——它们作为 MCP 客户端接入 GoodHub 的 `:8766`；**不是**其他 MCP server app（server-to-server 接入不在此模型内）。
- **形态变更（本节原裁决已翻转）**：原定「桌面平台先记录待完成 → 宿主批量处理」的异步队列形态**未采用**；实际采纳**实时 RPC 直调**——桌面平台经 `:8766/mcp`（Streamable HTTP，协议 2025-06-18）实时调用聚合工具面，由网关层统一 Bearer 鉴权 → L1/L2 权限卡片（含息屏 FSI 醒目呼叫 + 45s 超时熔断）→ PII 出站遮蔽 → ops.log 审计。决策依据与细则见 [design/thirdconnect.md](../design/thirdconnect.md) §7（TC5~TC8）。
- **连带影响**：原「无端口/鉴权/环检测/有界队列等 Server 侧依赖」的好处消失，F1.5/F1.12/F1.17 等整组需求**随之解冻并部分落地**（见 requirements.md F1 表）。其中**环检测**已按 SA-Q5 落地为「入站 Trace-ID 在途集合 + `hop_count` 上限 2」双保险（`lib/gateway/gateway_loop_guard.dart`）；**有界队列 429 仲裁**与 **SessionManager 会话隔离**经 SA-Q1 裁决显式关闭（延后，触发条件见 architecture.md §15 与待拍板清单）。
- **关联**：architecture.md 定位节与分期表 M1.5 行已改「已落地」（2026-10-15 回填）；requirements.md F1.5/F1.6/F1.8/F1.11/F1.12/F1.16/F1.17 已按实际实现状态重标。

## 收敛决策（七轮评审终裁）

- 转入 active 的阻断条件仅剩**契约回写闭环**（goodshare 仓 ai-app-split.md）：:8766 端口策略、ContentProvider 发现、UID 校验握手、x-mcp-* 注解组、resources/sampling/prompts 能力核查。
- M2 实验参数（RAM 6GB / 滑动窗口 N=6 / Token 1200 / max_turns=10 等）以代码配置常量进入 M1，初值允许调参。

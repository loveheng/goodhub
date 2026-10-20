---
dev-loop: decisions
format: v1
epic: m2-5-skill-refstore（已归档 2026-10-11）
total-merged: 0
last-merge: none
---

# m2-5-skill-refstore · decisions（自 context/decisions.md 迁入）

### ADR-006 M2.5 准入判定（2026-10-11，来源：dev-guide §1 步骤 0 / solution-admission）
- **决策**：判 S1 放行——按 architecture.md 七轮评审定稿的结构施工（三级 Skill §3 / RefStore 规格 §9 / Tier 分层 §14 均有正解落位），非补丁场景，六条否决信号不适用；结构性方案已存在，本轮为按图施工立项。
- **权衡**：施工分解与两处前置决策（D1 goodshare 实现归属 / D2 Progress 传输）落底子文档 docs/design/m2-5-skill-refstore.md §3/§4，拍板后随施工回写。
- **收敛条件**：施工中出现偏离既定结构的实现倾向（SQLite 暂存池元数据、三路合并、$ref 外泄语义放松等已否决项复萌）→ 当场回本 ADR 重评，禁止以补丁绕行。

### ADR-007 M2.5-D1/D2 施工前置拍板（2026-10-11，来源：M2.5 台账确认）
- **决策**：**D1 = goodshare 侧同程实现**——契约扩展 + prompts/resources 能力在 goodshare server 本里程碑落地（空桩转真实现），CoW/Resources 有真数据源可联调；**D2 = Progress 走 POST 响应 SSE 帧流**——MCP Streamable HTTP 标准允许 POST 响应回 SSE 帧，progress 通知夹带帧间、终帧仍含 result；goodhub `_decodePayload` 已兼容 SSE 帧，改动收敛 goodshare 侧响应写法。
- **权衡**：D1 备选「只修契约」使 T6 CoW / T7 Resources 对接空转，里程碑价值打折；D2 备选轮询违背通告语义（引入空转与宿主状态机，否决）、垫片后移则 >3s 工具「Loading 死等→误 Abort」问题延续。SSE 帧流的代价：goodshare tools/call 响应单 JSON → SSE 帧流，须核对桌面桥与直连客户端兼容性。
- **收敛条件**：桌面桥/直连客户端因 SSE 帧流破裂且短期无法修复 → progress 通道降级回 Tier 2 垫片纯 Loading（能力声明回退，降级不抛异常）。


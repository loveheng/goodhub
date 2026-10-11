---
dev-loop: memory
format: v1
epic: m2-5-skill-refstore
total-merged: 3
last-merge: 2026-10-11
---

# m2-5-skill-refstore（M2.5：Skill RefStore · prompts/resources · progress SSE）

- [挂载] docs/design/m2-5-skill-refstore.md（内容 SSOT：范围/T1~T7 分解/实现注记/§5 内部评审 C-1~C-4/§4 前置决策）
- [决策] ADR-006 判 S1 结构性引入放行（契约先行）；ADR-007：D1 prompts/resources goodshare 同程真实现、D2 progress 走 POST 响应 SSE 帧流（opt-in progressToken，桌面桥零破坏；收敛条件：桌面桥因 SSE 破裂 → progress 降级 Tier 2 垫片）——两 ADR 归档于本目录 decisions.md
- [结论] T1~T7 全实施（2026-10-11，双仓全绿 goodshare 792 / goodhub 240 + analyze 0）：契约 §3.6~§3.9、ServerCapabilities 防御协商+Polyfill（Tier 1 = prompts+resources 齐）、RefStore（$ref 句柄/30min TTL GC 联动删 tmp/>1MB 落盘 fail-fast）、HydratingExecutor 注水拦截（同源静默/查无立即 isError/跨源 fail-closed）、callWithProgress SSE 分帧收侧+心跳、SkillRegistry 三级+activate_skill 元工具、CoW 同步（CowSyncService+OverridesStore）
- [结论] 真机联调第一批通过（CPH2767）：Tier 1 协商/资源面 4 条/CoW imported×3/只读任务全链路两轮可视确认；抓真 bug：min_hub_version 占位 1.0.0 vs 宿主 0.1.0 → 修正后 imported
- [遗留] 第二批联调场景（L2 卡/progress 药丸/$ref 句柄注水真机补测）移交 M3——已随 m3-ui-subs-sampling 落地/移交
- [断点] 已完结（2026-10-11 ::done 归档）；goodshare M2.5 提交 3e1094f

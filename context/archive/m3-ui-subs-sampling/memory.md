---
dev-loop: memory
format: v1
epic: m3-ui-subs-sampling
total-merged: 3
last-merge: 2026-10-11
kind: temp
state: maintenance
---

# m3-ui-subs-sampling（临时 · M3：UI 全量 · Subscriptions · Sampling）

- [挂载] docs/design/m3-ui-subs-sampling.md
- [结论] 五项 T1~T5 全部实施（2026-10-11，双仓全绿 goodshare 795 / goodhub 278 + analyze 0）：T1 goodshare 订阅+sampling 协议线（GET SSE 下行/反向请求/ai_suggest_tags/契约 §3.10/§3.11/bufferOutput 修复）；T2 LoopToolProgress+CallCard 状态机+StuckWatcher（D4 双档）+Abort 链路（notifications/cancelled）；T3 $ref put 端（摘要化落池升级句柄，写管道闭环）；T4 服务大厅+CrossSourceConsentCard（D5 恒 L2 不豁免）；T5 收官验收（钉子复核+Tier 2 六口径+真机联调）
- [结论] 真机联调（CPH2767）：M3 capabilities 真机生效、progress 中途帧+sampling 反向推理闭环全通、L2 卡/C7 复现、E1 兜底路径可视正确
- [遗留] $ref 句柄注水真机补测推迟（2026-10-11 用户拍板：端侧模型整体推迟，全流程走通后再接端侧——届时自然解锁句柄链路验证）；句柄机制单测四例钉死，debug 页预填场景 B 文案已固化
- [决策] D1~D6 全拍板：一期全做/胶囊不纳入/sampling 滑动窗口配额/卡死双档仅提示/跨源恒 L2/create_skill 维持剥离——详见挂载文档 §4
- [收尾] 2026-11-06：$ref 句柄注水真机补测由 epics/on-device/todos.md B1 承接（不重复转办）；M3+ 订阅消费 UI 与 create_skill 复评见挂载文档；mcp_client.dart:139 DEGRADE 标记转全局风险待办

## 断点

- [断点] 已完结：M3 T1~T5 全交付（双仓 795/278 绿 + 真机 CPH2767 联调过）；正式 epic 改判临时并终态归档，句柄注水补测由 on-device B1 承接，1 处 DEGRADE 标记转全局风险待办

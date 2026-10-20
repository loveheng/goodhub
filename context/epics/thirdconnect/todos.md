---
memo: todos
format: v2
epic: thirdconnect
---
# thirdconnect · 域内待办
- [ ] [2026-10-19] (优化) (重:重) 存量债归本窗口处理（触发=本 epic 下次 ::bind / 恢复窗口时）：devlog 20 条待归并提炼进 memory.md 并清空追加区；待办行格式违规 2 处须逐行补标签；11 条人工打勾 [x] 已被 ctx-fix 回收进 done.md，须抽查 (域: thirdconnect) 行内容与源一致性 (src: ai, 存量债专项 QC3-a)

## thirdconnect 实现拆解（T-trans / G）

> 决策底：TC1~TC8 全确认（context/epics/thirdconnect/memory.md）；契约：docs/design/thirdconnect.md。
> 待确认台账 W1/W2 属 m4 周计划，不阻塞本 epic。

## 传输底座（T-trans）

## 网关（G）

## 插件接入 SDK（TC14）

> 把 AIDL / 1MB 分包对第三方透明化（thirdconnect.md §11）。SDK 仅 server 端 Stub；client 生命周期归宿主。详细任务卡：context/epics/thirdconnect/t-sdk-1.md

## 验收发现的后续项（2026-10-13 手动验收轮）
- [x] (功能) SDK `@McpTool` 补 `readOnlyHint` 注解并在 tools/list 下发 `annotations`：当前 SDK 不发注解 → 第三方插件全部工具双缺从严落 L2，PC 每次调用都要手机确认（C2 未知从严口径正确，但生态体验差——echo 类只读工具应能声明 L1 静默放行）；改动点=McpTool.kt 注解字段 + ToolDispatcher.toolsList 输出 annotations + sample 靶子声明 → **已完成（2026-10-21）**：SDK 0.2.0 已落地 hints（选择性下发，含 `readOnlyHint` / `destructiveHint`），宿主侧解析（`_meta` + annotations）与裁决（按是否显式声明）同步完成，已移入 `context/done.md`

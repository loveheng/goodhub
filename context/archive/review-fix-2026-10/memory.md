---
dev-loop: memory
format: v1
epic: review-fix-2026-10
total-merged: 0
last-merge: none
state: maintenance
---

# review-fix-2026-10

- [挂载] docs/design/review-fix-2026-10.md

## 结论（2026-10-24 ::done 收尾）

- 审查修复轮完结：F1-F19 + P2 A 批 13 项 + B 批 2 项全部落地；全量门禁四连绿（arch-guard / drift-guard / analyze 0 / 全量 1185 全绿，+14 钉子）。
- F3 语义变更（SSOT）：单端点装配失败「失败即关 + 通告降级继续」（宁缺勿炸），旧抛错用例随语义改写。
- F16 依赖白名单立法：`kAllowedDomainEdges` + ui 直连/gateway 执行面白名单镜像 §1.0 矩阵；改矩阵须同轮改三处（standards §1.0 / 测试 / index.md 基线）。
- 拍板①：免鉴权强制绑 127.0.0.1（token 空 ⇔ loopback，ADB 兼容零损失，无凭据 LAN 可达结构不可能）。
- 拍板②：pruned 补入站 isProjected 边界校验；full 显式保持目录-only（visibility 非 ACL，对齐 §1.1 规则 7），裁决记录在 host-tools-gateway-export.md。
- widget 测试双世界教训：fake-async 下 dart:io 完成事件不推进、网络垫片行为不稳——Run 级 widget 断言用结构钉子或 runAsync 真实窗（已录 lessons.md 待归并）。
- A03 口径：agent_loop 在途重入禁止 = debugAssert（_out 非空即拒），Run 完成后复用由文档契约约束。
- P2 遗留：B 档 6 项按触发条件择机、C 档 3 项观察（分档与触发条件见挂载设计稿 §P2）；D 档 CHANGE_WIFI_STATE 实证否决。
- 真机冒烟（网关 token 迁移/免鉴权回环/更新 https 拒绝路径）已并入全局 todos 真机验收总账 ⑤，待用户执行。

## 断点
- [断点] 已完结：2026-10-24 全项目审查修复轮完结：F1-F19 + P2 A 批 13 项 + B 批 2 项全落地，门禁四连绿（analyze 0/全量 1185）；B 档 6 项与 C 档 3 项按触发条件择机（挂载设计稿 §P2），真机冒烟移交全局待办总账⑤

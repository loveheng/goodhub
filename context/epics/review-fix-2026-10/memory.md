---
dev-loop: memory
format: v1
epic: review-fix-2026-10
total-merged: 0
last-merge: none
---

# review-fix-2026-10

- [挂载] docs/design/review-fix-2026-10.md

## 本轮共识（2026-10-24 审查修复轮）

- **F1-F18 全部落地**（F9 网关广播为镜像已测形态修复、无自动钉子；F19 为 F1 测试过程中新发现的 P2 已登记待办）。全量门禁：arch-guard 绿 / drift-guard 绿 / analyze 0 issue / 全量 flutter test（验证账本见 devlog）。
- **F3 语义变更（SSOT）**：单端点装配失败从「抛错炸整轮」改为「失败即关 + 通告降级继续」（对齐 mountEndpoint/保留字分支宁缺勿炸）；旧「装配异常路径」用例已随语义改写。
- **F16 正向依赖白名单制已立法**：`test/architecture/dependency_rules_test.dart` 的 `kAllowedDomainEdges` + ui 直连白名单 + gateway 执行面白名单镜像 §1.0 矩阵与 index.md 基线——**新域级出向/白名单外直连即红灯**；改矩阵须同轮改三处（standards §1.0 / 本表 / index.md 基线）。
- **widget 测试双世界教训**：fake-async 下 dart:io 完成事件不推进（negotiate 永挂）；本沙箱出站被网络垫片拦截且行为不稳（时快 4xx 时永挂）——**Run 级 widget 断言用「结构钉子」或 runAsync 真实窗，网络路径不作确定性地基**；平台通道/真实 IO 混链用「真实窗↔pump」交替推进。

## 断点
- [断点] 下一步：剩余 = P2 批（设计稿「P2 择要」清单 + F19 连接中 abort 空操作）按需开工；真机冒烟（网关 token 迁移/更新 https 拒绝路径）待用户执行

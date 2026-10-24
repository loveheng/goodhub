---
dev-loop: memory
format: v1
epic: meta-upgrade
total-merged: 1
last-merge: 2026-10-24
---

# meta-upgrade

- [挂载] docs/design/meta-upgrade.md

## 决策（已拍板）

- **病根是框架级**：6 个同框架项目（goodhub/goodshare/goodAccount/goodTools/shiguang/goodTemplate）各自持有 arch-guard.sh 副本（192~269 行、同骨架、规则已分叉，合计 1267 行）——「回写不完整」不是 goodhub 个案，人工扫的漏检率随项目数放大。故**不做项目内补丁**，做框架级机械件。
- **三层分离（U1/U2 修正后的口径）**：① 引擎 `~/.agents/toolbox/scripts/drift-guard.sh`（全局池，零项目知识，多项目共用一份）② registry 数据 `<repo>/scripts/agent-tools/drift-registry.txt`（随代码同批版本化）③ CI 门禁 `test/architecture/drift_rules_test.dart`（Dart 镜像读同一 registry——CI 无 toolbox，对齐 dependency_rules_test 先例）。**数据与规则分离**：新规则只加 registry 数据行，不改引擎代码。
- **三类可机械判定**：BANNED 退役词条（token 级）/ CONST 单源常量（字面量级）/ OVERSIZE 超标登记核对（行数级）。**诚实边界**：散文级集合描述一致性（三档 vs 四档）机械不可靠 → 不扫描，归 `::audit` 人判；context/ 是历史账归属 → 不扫。
- **CI 侧不需要新步骤**：Dart 镜像随既有 `flutter test` 全量进 CI（ci.yml 无需改动）——与 arch-guard 需显式加一步不同（后者是 shell 版）。
- **实施中修正的两处**：
  - `grep -n` 单文件操作数不输出文件名 → 解析把行号当路径 + 整行注释未被剔除；处置 = 扫描器一律加 `-H`（已成教训条目）。
  - CONST 搜索面收窄到 **lib/ 生产代码**（test/ 不扫）：测试字面量是有意的独立钉子，常量变更经测试失败自曝；docs 散文提及不判（版本号在文档里是正常叙述）。
- **顺带收敛的真双源**：网关端口 8766 此前两处声明（gateway_server 默认 + gateway_controller 入参默认）+ UI 文案与 gateway_control 各写一份 → 统一 `kGatewayDefaultPort`（gateway_server 声明，其余三处引用；UI 经 gateway_api 门面转出，守住 ui→gateway_api→gateway 单向纪律）。
- **本轮抓到的自伤**：drift-guard 首跑即命中我自己在 index.md 写的登记说明行（退役词条出现在文档里）→ 加 `drift:keep` 行内显式豁免（可见可审计，禁静默豁免）。

## 进度（活事实）

- 三层件已落地并全绿（2026-10-23：drift-guard 自检 PASS + 变异探针注入即红/还原复绿 + Dart 镜像同咬 + 全量 1133/1137 绿）；goodTemplate 移交件已产出（handoff-goodtemplate.md），等用户执行（见断点）
- 并行会话在 projection_pipeline.dart 加 owner 档时留下半成品编译红——本轮只补 mcp_gateway_handler policy switch 防御性 case（owner => 'owner'）恢复可编译，其语义/设计归 gateway 并行会话，未触碰

## 断点
- [断点] 下一步：用户执行 goodTemplate 移交件（context/epics/meta-upgrade/handoff-goodtemplate.md）并按 §4 校验命令验收；存量 5 项目按需采纳；后续 epic：arch-guard 引擎去重（6 副本 → 引擎全局 + 各项目 rules-as-data）

---
dev-loop: devlog
format: v1
epic: meta-upgrade
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-23] [变更]: 元体系升舱落地（用户授权开工）：三层分离——① 引擎落全局池 ~/.agents/toolbox/scripts/drift-guard.sh（零项目知识，6 同框架项目共用一份；BANNED 退役词条/CONST 单源常量/OVERSIZE 超标登记三类 + --json + 金丝雀自检，坏样本取自本轮真实现场）② registry 数据留本仓 scripts/agent-tools/drift-registry.txt（首版 6 条：旧工具名 + D1 旧键 ?strategy=/scope= + kMcpProtocolVersion/kGatewayDefaultPort 单源 + 800 行超标登记核对）③ CI 侧 Dart 镜像 test/architecture/drift_rules_test.dart（读同一 registry，CI 无 toolbox）；顺带收敛两处真双源：网关端口 8766 双声明 → kGatewayDefaultPort 单源（gateway_server/gateway_controller/gateway_control/gateway_section 四处同引）
- [2026-10-23] [验证]: drift-guard --self-test → PASS（坏样本≥4处/净样本0误报/缺registry放行）；对 goodhub 首跑 → OK；真实仓变异探针：注入 ?strategy=full → 抓（file:line 正确），还原复绿；Dart 镜像同探针 → 同样咬人；analyze → 0 issue；flutter test → 1133 全绿；arch-guard → OK；docs-lint → OK（补 README 索引后）；pcg --self-test → PASS
- [2026-10-23] [变更]: goodTemplate 跨仓移交件产出（AI 只读勘察 + 产件，跨仓写入由用户执行）：context/epics/meta-upgrade/handoff-goodtemplate.md —— 含目标仓现状勘察结论表、① registry 骨架（cat > 全文，OVERSIZE 行因模板无 docs/project/index.md 暂不启用）② Dart 镜像 cp 命令（零项目知识，原样复制）③ pcg 分派块全文 + 头部/usage 三处同步行 ④ 校验命令 5 条（含变异探针及其适用前提说明）⑤ 可选登记（模板无 docs//.agents/ 故跳过）⑥ 验收标准 ⑦ 回滚路径
- [2026-10-23] [验证]: 移交件步骤 1~2 于临时目录复现验证：引擎自检 PASS；骨架 registry（全注释行）扫描 → OK；sed 抽取 registry 骨架落盘合法；goodTemplate 只读勘察确认：无 docs//.agents//CI、pcg 既有 docs-lint 已走全局池（同构先例）、toolbox init --project 不复制全局脚本（引擎不落副本成立）
- [2026-10-23] [变更]: 并发编辑协调（并行会话同改 gateway 域）：并行会话在 projection_pipeline.dart 新增 owner 档（宿主内部档·无 URL 入口·海关全豁免）后收尾时 tree 处于半成品——mcp_gateway_handler 的 policy switch 未覆盖 ProjectionStrategy.owner → 编译红；本轮按「不改其语义、只补防御性分支」补 case（owner => 'owner'，真走到即说明有代码绕过入口约束），恢复可编译；未触碰其 pipeline 语义与 owner 档设计
- [2026-10-23] [验证]: flutter analyze → 0 issue（含并行会话最新改动）；flutter test --timeout 180s → 1137 全绿（含其 owner 档新用例 4 例）；arch-guard → OK；drift-guard → OK；docs-lint → OK

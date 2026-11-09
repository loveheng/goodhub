---
dev-loop: devlog
format: v1
epic: integration-test-refactor
total-merged: 8
last-merge: 2026-11-09
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-11-09] [变更]: R4 观测面固化落地：index.md 文档落点登记 integration-test-refactor.md（active）+ 代码落点登记 gateway_external_probe（NON-TEST 身份 / 标准消费方 conformance probe）；SKILL.md 探针行更新 + 追加跨仓 conformance 验收入口；设计稿状态 draft→active
- [2026-11-09] [note]: 真机卡 logo 排障：设备上装的（含 12:07 那发）实为 gateway probe 测试壳（kernel_blob 特征串铁证），lesson「测试壳覆盖安装」复发；重建正式入口装回恢复，SSOT 修正=devlog「正式 APK 重建完成」记录与实况不符（12:07 产物仍是测试壳）。USB 断连经全仓检索排除代码因素（无 USB 操控面），判线材接触问题。收尾附机械取证判据入 lessons（kernel_blob grep 特征串）
- [2026-11-09] [变更]: SDK 0.6.0 升级收尾：mavenLocal 兜底仓从 0.1.x 补发到 0.6.0（contract/plugin-core 经 toolbox run sdk-dep + ai-client/ai-runtime 显式补发）；check-contract-sync 全绿（宿主坐标 0.6.0 = 契约仓 0.6.0，AIDL v1）；sdk-dep.sh 修补=根聚合 publishToMavenLocal 只落两件，改四工件显式发布+逐一 AAR 校验（对齐 CHANGELOG 0.6.0 发布链口径），全链回归通过
- [2026-11-09] [变更]: v1.3.0(2017) 发布 R2 + 三仓提交推送（goodhub 48b6e79+0a98e6e / goodshare 3a1a937 / SDK v0.6.0 tag 此前已发）。排障=R2 S3 端点瞬时不可达（重跑自愈）；SSOT 修正=release-r2.sh .env 的 CHANGELOG="" 在 source 时清空调用方传入的发布说明（清单曾回退成版本号提交信息，已修线上+脚本改「.env 只补缺不覆盖」）

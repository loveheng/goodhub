---
dev-loop: memory
format: v1
epic: integration-test-refactor
total-merged: 8
last-merge: 2026-11-09
---

# integration-test-refactor

- [挂载] docs/design/integration-test-refactor.md

## 断点
- [断点] R4 观测面固化已落地（2026-11-09）：index.md 双表登记（文档落点 + 探针 NON-TEST 代码落点）、SKILL.md 探针行改标准消费方 conformance probe + 跨仓验收入口、设计稿 draft→active。epic 主线完成；遗留 = sampling 反向断言二期进 SDK conformance（依赖宿主 wireSampling 接线）；两仓 + SDK 仓改动均未提交待用户指令

## 决策
- [决策] 判定式（落点裁决，design §2）：断言 goodhub 内部行为 → goodhub 仓 test//integration_test/；断言契约互通 → SDK 仓 conformance 套件；断言对端 App 内部行为 → 对端仓。R1（wal 外迁）/R2（binder、toolrouter 换 dummy 对端）/R3（conformance 套件）均按此裁决执行
- [决策] R3 形态：PC 侧 JSON-RPC 驱动 + 两级网关就绪模式（probe=自动拉起 gateway_external_probe + adb forward / direct=外接 host:port）；断言面 A1-A4（initialize / SHARED 目录可见 / PRIVATE 不可见 default-deny 负向钉 / SHARED tools/call 真调通）；每接入方一份薄配置 configs/<app>.json；blob 分片（mcp-blob://）不进套件留扩展点
- [决策] R4 固化 = 登记为对外联调标准通道 SSOT，杜绝「来一个接入方留一个探针文件」：gateway_external_probe 为 NON-TEST 探针（装配 faces + 0.0.0.0:8766 保活 120s，禁当回归 e2e 跑），标准消费方 = conformance/run.py probe 模式；三层观测面（conformance 断言 / 网关探针 / debug 桥）已入 index.md 双表与 SKILL.md
- [决策] goodshare ai-app-split.md §10 同轮登记接缝裁决：联调验证随契约走（单副本 SDK 仓），禁止各接入方仓重复写宿主联调测试；goodshare 样本 = 旧式全 PRIVATE 负样本形态

## 验证账本
- [2026-11-09] flutter analyze 0 issue；local_plugin_manifest_gate_test 3/3 绿；goodshare 仓新文件 analyze 0 issue
- [2026-11-09] 真机 3B161700Y0600000 五件套全绿（trust_gate/dummy_binder/dummy_toolrouter/ai_complete/thirdconnect，exit 0）；check-same-signature SAME；install-dummy-plugin OK；正式 APK 重建完成
- [2026-11-09] conformance 真机实证：py_compile 绿；dummy 正向 6/6 + goodshare 负样本 4/4 均 exit 0；正式宿主包已按互斥纪律重装
- [2026-11-09] R4 收尾：toolbox run docs-lint OK（index.md / SKILL.md / design 稿变更后）

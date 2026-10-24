---
dev-loop: devlog
format: v1
epic: review-fix-2026-10
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-24] [变更]: F1-F8+F10 落地：F1 PopScope 挂 statusListenable 重建域（结构钉子）；F2 close 级联停 GET SSE 监听；F3 装配失败路径 close client+降级继续（旧 throwsA 用例随语义改写）；F4 debug orchestrator mount 传 release+双路兜底；F5 activate_server_tools 改走 requestSlot 提交点事务；F6 _send 发送闩防双发；F7/F13 trusted_plugins 单例 future 缓存+写串行+签名指纹复核（挂载两调用点传指纹）；F8 消费循环 dispose/断通道单步间复查即停；F10 投影切换经 onProjectionApplied 写回会话条目（idle GC 重建不回退）。另删工作区临时诊断件 zz_diag_test
- [2026-10-24] [验证]: flutter analyze 0 issue；分域测试全绿（chat_page 9、subscription 12、mcp_runtime 18、debug_orch 5、discovery+chat_run 29、trusted_plugins+mount+panel 10、consume_loop 11、gateway 三组 41、update 18、endpoints 16、gateway_section+settings 20）
- [2026-10-24] [变更]: F9-F18 落地：F9 网关广播拷贝遍历+单订阅者包裹（镜像 heartbeat 已测形态，无自动钉子——死连接同步抛不可用真实 socket 确定性复现）；F11 网关 Token 迁 SecureKeyValue+首启迁移删明文；F12 旧明文 apiKey 迁移后清理（SharedPreferencesLike 增 remove）；F14 更新清单强制 https+sha256 必填（回环 http 豁免）；F15 §1.0 矩阵 app/gateway_api/task 行账实修正；F16 dependency_rules_test 补正向域级白名单矩阵+ui 直连/gateway 执行面两张文件级白名单镜像——首轮即抓出 5 处账实差（app→llm、app→resources、task→core、ui 两段漏登、coordinator→app 反向边，后者 McpCatalog endpointStore 改必传斩断）；F17 host-tools-gateway-export draft→active；F18 workflow skill drift-guard 裸命令改显式 --root（根治移交 meta-upgrade）
- [2026-10-24] [验证]: gateway_section+settings_page 20 绿；update 18 绿（含 F14 拒绝组）；server_endpoints 16 绿；docs-lint 0；dependency_rules 12 绿

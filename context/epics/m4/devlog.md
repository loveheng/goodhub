---
dev-loop: devlog
format: v1
epic: m4
total-merged: 1
last-merge: 2026-10-11
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

- [变更] 2026-10-13 T5-Server 节点卡（纯代码部分）：`ServerEndpoint` 增 `enabled` 挂载位（JSON 缺省 true 零迁移；copyWith 贯通 → 聊天页 ⚙ 编辑表单经 copyWith 不重置）；新建 `lib/mcp/server_probe.dart`（ServerProber 计时握手+tools/list 计数，401/403→authDenied 与离线显式区分，失败不抛穿结果承载，clientFactory 注入位）
- [变更] services_hall_page 节点卡面板替换占位（渲染端口/延迟/工具计数/鉴权态 + 在线点语义 + 挂载开关落盘 + 「探测全部」按需探活不自动网络化；注入位 endpointStoreOverride/probeOverride；生产装配与 chat_page._epStore 同文件同口径）；chat_page._send 过滤 enabled=false + 卸载通告
- [验证] 新增 test/mcp/server_probe_test.dart 7 例（在线/403/401/离线/超时/形状异常/apiKey 形态）+ server_endpoints_test 增 2 例（enabled round-trip/迁移缺省）+ test/ui/server_nodes_panel_test.dart 7 例（渲染/探测回填/带令牌/403/离线/卸载落盘/重挂载）；全量 398 绿 / analyze 无新增（存量 1 info：gateway_loop_debug_page:635 deprecated_member_use，Flutter 3.33 弃用，见 misc 待办）
- [note] widget 测试教训两条：① ServicesHallPage 任一面板初始化失败置 _error 会替换整个 ListView（面板级短路）——注入某面板假件必须四面板全注入（同 byok_panel_test 先例）；② 测试体内直调真实文件 I/O（store.save）在 FakeAsync 永不归还挂死 10min——必须套 tester.runAsync（settleIo 同源纪律）
- [SSOT 修正] docs/design/m4.md T5 进度节回填 Server 节点卡段；goodhub-index 登记节点探活/节点卡两行
- [变更] 2026-10-13 B2 强耦合收尾（goodshare 侧已落地 B1/B2/B3/R2）：goodhub `AndroidManifest.xml` 加 `<uses-permission android:name="com.zzh.goodhub.permission.MCP_SERVER"/>`——goodshare Service 已挂 signature 权限，不声明则 bind 抛 SecurityException；两包须同签名同批出包
- [note] B1/B3/R2 无需宿主改码：BinderTransport 契约「插件 JSON-RPC error 帧原样回传协议层裁决」（-32000 超时帧自然走 McpRpcException）；error 帧 id 回显是宿主 _pendingTerminal 关联受益方；ready 5s 与宿主冷启 5s 对齐后宿主侧不动


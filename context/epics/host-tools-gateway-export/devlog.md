---
dev-loop: devlog
format: v1
epic: host-tools-gateway-export
total-merged: 5
last-merge: 2026-10-23
---
- [2026-10-23] [变更]: 机制归一第一步「owner 档」：ProjectionStrategy.owner 宿主内部档（海关全豁免+防火墙照常+前缀命名），parse 对网关侧显式拒绝（防 MO6 崩塌）、describeGatewayProjection fail-loud 守卫；单测钉死 owner 目录集 == focusedSchemas 语义等价（机制归一：App 视图=管道 owner 求值）；设计稿策略表+铁律段同步
- [2026-10-23] [验证]: flutter analyze → 0 issue；flutter test test/gateway/ → 131/131 全绿（+4 owner 档用例）
- [2026-10-23] [变更]: 装配层合一 Expand 件：①McpToolFace 进度多路复用（addProgressListener/removeProgressListener + _emitProgress 扇出单点，_hasProgressConsumer 决定流式）——网关挂载 face 无构造期 onProgress，chat 复用经监听器不丢进度；②GatewayController 消费者 API（faceFor/facesChanged/ensureEndpointMounted——幂等直返，未挂载走 rescan 单点装配路径，挂载逻辑零拷贝）；③设计稿拓扑节消费者视图条目。Contract（chat 切换共享源）下轮
- [2026-10-23] [验证]: flutter analyze → 0 issue；flutter test test/gateway/ + test/mcp/progress_stream_test.dart → 149/149 全绿（+6 Expand 用例，存量零改动=行为零变更）
- [2026-10-23] [变更]: 装配层合一 Contract 件：McpRuntime.assemble 增 sharedFaces 借用缝——chat 传 GatewayController.shared.faces，命中即借用（跳过新建/协商/连接，消双实例双冷启动）；借用边界=close 只摘监听不关共享 client、abort 不取消借用面（跨消费者取消是踩踏，服务端 90s 超时兜底）、sampling/elicitation/CoW 保留源侧接线；未命中端点走旧自建兜底（缺省空表=旧路径，测试隔离不受影响）；chat_page _loadEndpoints 预热 ensureEndpointMounted + _send 传共享表；设计稿拓扑节 Contract 条目
- [2026-10-23] [验证]: flutter analyze → 0 issue；flutter test test/coordinator/ + test/gateway/ + progress_stream_test → 547/547 全绿（+2 借用缝用例，存量零改动）

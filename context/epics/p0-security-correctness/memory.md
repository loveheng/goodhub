---
dev-loop: memory
format: v1
epic: p0-security-correctness
total-merged: 1
last-merge: 2026-10-17
---

# p0-security-correctness

- [挂载] docs/design/p0-security-correctness.md

## 已闭环（2026-10-17 归并自 devlog 17 条）

- **P0-C 依赖护栏加固**：`test/architecture/dependency_rules_test.dart` 重写为通用扫描器（剥注释、覆盖 import+export、不锚行首，折行/转发/package 写法可抓）+ 规则表 6 条（R1 core 零出向 / R2 mcp·sandbox↛coordinator / R3 mcp·sandbox↛llm / R4 ui↛gateway_controller / R5 gateway↛ui / R6 禁引 mcp/tool_router.dart）+ 金丝雀与防空集假绿；arch-guard.sh 增 R4~R8 shell 秒级镜像（金丝雀 9 处）；新建 arch-deps.sh（flutter test 全套，--self-test 注入验证），pre-commit-gate.sh 增 ARCH_GATE_FULL=1 开关（默认秒级版，flutter test 12s 超钩子 10s 预算）；顺带清零两处存量 R1 UI dart:io 违规（update_page 持路径不持 File、error_copy 异常判定下沉 core/errors/transport_error_kind.dart）——处置选修复不加白名单（白名单纪律只减不增）
- **P0-C 防线虚设实证修复**：conversation_drawer_test 隔夜腐化（fixture 写死日期 vs 真实时钟恒红）→ 改相对今天构造；纪律=「今天/昨天」类断言一律相对构造，禁写死绝对日期
- **P0-A 文件级互斥**：新增 `lib/core/storage/keyed_write_queue.dart`（按路径键进程级串行写队列，链排空即惰性除名）；SequentialFileWriter 互斥链委托该注册表（签名不变五调用点零改）；MemoryStore/WorkspaceStateStore 复合读改写单元接入（不同会话仍并行）；ioDrained 两段排空。**用户裁决：不做 underSupportDir 单例化，维持 factory 语义**。变异验证：互斥键回退实例级后 5 用例立红（100 行丢 50、memory.md 被整条覆盖），还原复绿
- **P0-B 网关安全上下文隔离**：GatewaySecurity.forSession 派生实例（只共享无状态裁决矩阵，豁免集随连接独立）；豁免键强制 `serverId::toolName`；Handler.forSession 派生 + disposeSession（idle GC 与停服两路径回收）；guard 补必填 serverId。变异验证：三处回退后用例立红还原复绿
- **P0-B 装配句柄释放**：取证发现挂载原语原本完全没有释放通道（比原判更深）——新增 McpMount 带 close、mount 接 release 闭包、mountEndpoint 交出 client.close；gateway_controller 建 _mounted 句柄表 + _unmountAll（先清 faces 再逐个 close），重扫/停服/起服失败 finally 三路径全回滚
- **GatewayController 装配注入位**：LocalPluginSource/PluginTrustGate 接口化 + endpointStore/supportDir 工厂注入（默认值=原实现）；新增 gateway_controller_mount_test（重扫先释放、起服失败零残留）；修复上轮误改（_unmountAll 自递归与 _assemble 丢释放两处互换）
- **CI workflow（债 #13 收口）**：新增 `.github/workflows/ci.yml`（push/PR main：analyze + 全量 test --timeout 180s + arch-deps；Flutter 3.47.5 stable 对齐本地）；arch-deps.sh 补执行位。Actions 首跑绿灯待推送后确认

## 验收基线（截至 2026-10-17）

flutter analyze 0 issue；全量 734/734 全绿；arch-guard 0 违规；arch-deps 10/10 含金丝雀

## 断点

- [断点] 下一步：下一步：p0 候选①②已落地（注入位+CI workflow，本地验证全绿）；剩余=提交推送+P0-B 真机冒烟（用户执行）；P1 盘点已移交给新 epic window-slim

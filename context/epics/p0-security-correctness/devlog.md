---
dev-loop: devlog
format: v1
epic: p0-security-correctness
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-17] [变更]: P0-C 依赖护栏加固：test/architecture/dependency_rules_test.dart 重写为通用扫描器（先剥行注释与块注释再匹配 import 与 export、不锚行首，覆盖折行与 export 转发）+ 6 条规则表（R1 core 零出向 / R2 mcp 与 sandbox 不依赖 coordinator / R3 mcp 与 sandbox 不依赖 llm / R4 ui 不直连 gateway_controller / R5 gateway 不依赖 ui / R6 禁引 mcp/tool_router.dart）+ 扫描器金丝雀 3 例（折行与 package 写法与 export 转发能抓到、注释不误报、R6 自身豁免）、防空集假绿 1 例
- [2026-10-17] [验证]: flutter analyze → No issues found；flutter test --timeout 180s → 717/717 全绿；bash arch-guard.sh → 0 违规；bash arch-deps.sh --self-test → PASS（注入违例被拦、还原放行）
- [2026-10-17] [变更]: P0-C 门禁加固续：arch-guard.sh 增 R4 到 R8 的 shell 秒级镜像（与测试规则表同源，金丝雀从 3 处扩到 9 处）；新建 arch-deps.sh 手动工具跑 flutter test test/architecture/，其 self-test 向 lib/sandbox 注入违例 import 验证护栏会红、还原后放行（trap 清理注入件）；pre-commit-gate.sh 增 ARCH_GATE_FULL=1 开关追加执行，默认只跑秒级 shell 版（flutter test 单次约 12 秒，超 pre-commit 钩子 10 秒预算）
- [2026-10-17] [变更]: 顺带清零两处存量 R1（UI 层 import dart:io）违规：update_page.dart 改持路径 String 不持 File 句柄；error_copy.dart 的 SocketException 与 HttpException 判定下沉新建 core/errors/transport_error_kind.dart，UI 只消费 TransportErrorKind 枚举。不清零则新门禁会挡住所有提交；处置选修复而非加白名单（白名单纪律只减不增）
- [2026-10-17] [变更]: 修复 conversation_drawer_test.dart 隔夜腐化用例：fixture 写死 DateTime(2026,10,16,9,30) 而被测 fmtTime 拿真实 DateTime.now 比日历日，2026-10-17 起恒红；本仓长期不跑测试故从未暴露，是 P0-C 防线虚设的实证。改为相对今天构造（跨天样本用 day-2）、期望值从 fixture 推导
- [2026-10-17] [变更]: epic 挂载与旧账归并：mount-init 切换前置拦截 arch-hardening devlog 待归并 24 条，按 dev-loop 第四节执行归并（提炼进 memory 已闭环与验收基线两节、追加区清空、头部 total-merged 1、断点行原样保留），随后挂载 p0-security-correctness 并切绑 CURRENT
- [2026-10-17] [验证]: 未执行: 本轮为文档与记忆维护，无代码变更可验证
- [2026-10-17] [变更]: P0-A 文件级互斥落地：新增 lib/core/storage/keyed_write_queue.dart（按规范路径键的进程级串行写队列，链排空且无后继即惰性除名防无界增长）；SequentialFileWriter 互斥链由实例字段改为委托该注册表（对外签名不变、五个装配调用点零改动）；MemoryStore 与 WorkspaceStateStore 的复合读-改-写单元一并接入（键分别为沙盒目录、目录加会话 id，不同会话仍可并行），ioDrained 改为复合链与 writer 链两段排空。用户裁决：不做 underSupportDir 单例化，维持 factory 按需新建语义
- [2026-10-17] [验证]: flutter analyze → No issues found；flutter test test/core/storage/ → 8/8 全绿；flutter test --timeout 180s → 725/725 全绿；变异测试：把互斥键回退为实例级后用例 1/2/3/4/8 立红（用例 1 实测 100 行只剩 50 行、用例 8 的 memory.md 被后写实例整条覆盖），还原后复绿——证明断言有效非假绿
- [2026-10-17] [变更]: P0-B 网关安全上下文隔离：GatewaySecurity 新增 forSession 派生实例（只共享无状态的裁决矩阵与审计汇，会话豁免集随连接独立）；豁免键强制 serverId 加双冒号加 toolName（无前缀工具归 local 命名空间）；GatewayHandler.forSession 改为派生安全上下文，新增 disposeSession 释放入口并在 idle GC 与停服两条回收路径调用；guard 增必填 serverId 入参；既有 gateway_security_test 七处调用同步补参
- [2026-10-17] [验证]: flutter analyze → No issues found；flutter test test/gateway/ → 50/50 全绿（含新增 7 条）；flutter test --timeout 180s → 732/732 全绿；变异测试：三处修复回退（共享 security / grant 仅 tool 名 / mountEndpoint 不交释放通道）后用例 2、3、6 立红，还原后复绿
- [2026-10-17] [变更]: P0-B 装配句柄释放通道：取证发现挂载原语只回 face/caps/schemas，完全没有释放通道——mountEndpoint 内部创建的 client 调用方拿不到引用，网关重扫与停服无从关闭（比原判的丢弃句柄更深一层）。新增顶层类型别名 McpMount 带 close，mount 接收调用方 release 闭包、mountEndpoint 交出 client.close；gateway_controller 建 _mounted 句柄表与 _unmountAll（先清 faces 再逐个 close），重扫、停服、起服失败 finally 三条路径全部回滚
- [2026-10-17] [验证]: 未执行: 与上一条同轮验证，见上

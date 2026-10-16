---
status: draft
updated: 2026-10-17
---

# p0-security-correctness：P0 缺陷修复施工稿（文件互斥 / 网关安全上下文 / 依赖门禁）

> **定位**：2026-10-17 全仓架构盘点判出的三条 P0 致命暗雷的施工勾稽表。**背景与诊断**见本轮盘点结论（三条根因：对象互斥伪装文件互斥、per-connection 投影只投影目录未投影安全上下文、护栏写在文档里不写在代码与 CI 里）。范围跨 `core/storage`、`sandbox`、`gateway`、`test/architecture`、`scripts/agent-tools`——**跨域，单独立项**（不并入已收官的 arch-hardening）。

## 1. 三条 P0 与当前状态

| # | 缺陷 | 状态 |
|---|---|---|
| **P0-C** | 依赖防线与 CI 虚设：护栏只盖 2/5 红线、正则只匹行首单行 import、门禁从不跑测试 | ✅ **已完成**（2026-10-17） |
| **P0-A** | `SequentialFileWriter` 的互斥链是**实例级**而非**文件级**，多个 `underSupportDir` 工厂实例同写同一文件 → 读-改-写交错静默丢数据 | ✅ **已完成**（2026-10-17，8 条断言 + 变异验证） |
| **P0-B** | 网关 `forSession()` 共享 `security` 引用 → `_sessionGrants` 跨 PC 会话提权；挂载原语无释放通道 → 重扫/停服泄漏 client | ✅ **已完成**（2026-10-17，7 条断言 + 变异验证） |

## 2. P0-C 已完成内容（变更账目）

- `test/architecture/dependency_rules_test.dart` 重写为**通用扫描器 + 规则表**：先剥注释（行/块）再匹配 `import`/`export`，不锚行首（覆盖折行与 export 转发）；6 条规则 R1 core 零出向 / R2 mcp·sandbox↛coordinator / R3 mcp·sandbox↛llm / R4 ui↛gateway_controller / R5 gateway↛ui / R6 禁引 `mcp/tool_router.dart`；附加「扫描器非空（防空集假绿）」与 3 例扫描器金丝雀。
- `scripts/agent-tools/arch-guard.sh` 增 R4~R8 **shell 秒级镜像**（与测试规则同源），金丝雀从 ≥3 扩到 ≥9。
- 新工具 `scripts/agent-tools/arch-deps.sh`（manual）：跑 `flutter test test/architecture/`；`--self-test` 注入违例 → 护栏变红 → 还原放行（trap 清理注入件）。
- `pre-commit-gate.sh` 增 `ARCH_GATE_FULL=1` 开关追加跑 arch-deps——**默认只跑秒级 shell 版**，因 `flutter test` 单次 ~12s 超 pre-commit 钩子 10s 预算。
- 顺带清零两处**存量 R1（UI 层 dart:io）违规**（不清零则新门禁挡住所有提交）：`update_page.dart` 改持路径 `String` 不持 `File`；`error_copy.dart` 的 `SocketException`/`HttpException` 判定下沉 `core/errors/transport_error_kind.dart`，UI 只消费 `TransportErrorKind` 枚举。
- 顺带修复 `conversation_drawer_test.dart` 的**隔夜腐化**用例（fixture 写死绝对日期，被测 `fmtTime` 比真实日历日 → 2026-10-17 起恒红；本仓长期不跑测试故从未暴露）。

## 3. P0-A 方案（文件级互斥）

### 3.1 关键判断：只改 writer 层不够

丢数据的真正位置是**复合读-改-写单元**——`memory_store.dart` 与 `workspace_state_store.dart` 各有一条实例级 `_tail` 串行「读全量 → 改 → 整体重写」。即使底层 write 已串行，两个实例仍会各自读到同一份旧内容、最后一次写覆盖前一次。**两层都要 keyed**。

### 3.2 施工步

| 步 | 交付 |
|---|---|
| 1 | 新增 `lib/core/storage/keyed_write_queue.dart`：进程级 `Map<path, _Chain>` 注册表；`enqueue(key, task)` / `settled(key)` / `@visibleForTesting keyCount`；**key 惰性回收**（链排空且无后继即除名，防长会话累积） |
| 2 | `SequentialFileWriter` 的 `_enqueue`/`settled` 委托 keyed 队列——**对外签名不变，五个调用点零改动** |
| 3 | `MemoryStore._enqueue` 委托 keyed 队列，key = `dir.path`（三件套共用目录锁，保复合单元整体互斥）；`ioDrained` 语义不变（自身链收敛 + 三个 writer 排空） |
| 4 | `WorkspaceStateStore._enqueue` 委托 keyed 队列，key = `'${dir.path}::$conversationId'`（按会话粒度锁，不同会话仍可并行） |

### 3.3 裁决（用户拍板 2026-10-17）

**不做 `underSupportDir` 静态实例缓存（单例化）**，维持原有 factory 语义。理由：① 第 1~4 步已彻底消灭「跨实例并发写同一文件丢数据」的物理根因，单例化属冗余；② 静态缓存打破「按需新建、用完可 GC」的生命周期直觉，且会破坏依赖实例隔离的既有单测；③ 结论 = 严格按 1~4 步在底层焊死并发安全，**上层 API 与调用点完全无感，零破坏性改动**。

### 3.4 测试断言（8 条）

1. 跨实例 append 不丢（两实例 ×50 条 → 100 行）｜2. **跨实例读-改-写不丢**（两 `MemoryStore` 并发 `addEntry` → 2 条都在）｜3. WorkspaceState 两实例并发 upsert 不同 key 都在｜4. `settled` 跨实例可见｜5. 不同路径不互相串行｜6. key 不泄漏（drained 后 `keyCount == 0`）｜7. 失败不毒化队列（一次抛错后后续仍成功）｜8. 既有 `memory_kernel_test` / `memory_governor_test` / `workspace_state_store_test` 无回归。

## 4. P0-B 方案（网关句柄与 per-session 安全上下文）

### 4.1 装配句柄接管（`gateway_controller.dart`）

- 新增 `final Map<String, McpAssembly> _mounted`（serverId → 句柄）；挂载成功同时入表。
- `_unmountAll()`：逐个 `await a.close()`（`McpAssembly.close` 已幂等，`mcp_runtime.dart:247`）→ 清表 → `faces.clear()`。替代 `:145` 的裸 `faces.clear()`。
- `start()` 加起服标志：`server.start()` 抛错时 `finally` 内若未起服则 `await _unmountAll()`（当前 `:116` 装配成功 + `:118` 绑端口失败会留下全套悬空 client）。
- `stop()` 末尾 `await _unmountAll()`。

### 4.2 安全上下文投影化

- `GatewaySecurity.forSession()` 派生实例：**只共享无状态的裁决矩阵（`_classifier` static）与审计汇（`opsLog`）**，会话豁免集逐会话独立。
- `GatewayHandler.forSession()` 的 `security: security` 改为 `security?.forSession()`（当前 `:100` 是同一引用，导致 PC-A 授权 PC-B 免确认）。
- grant key 强制 `'${serverId}::${toolName}'`（无前缀的本地/元工具用 `'local'`）——跨 server 同名工具不互免。
- 连接断开即清：session 回收路径（idle GC / stop）调 `handler.security?.resetSessionGrants()`。

### 4.3 测试断言（6 条）

1. 会话豁免不跨 PC（fake delegate 计 confirm 次数，sessionB 仍须弹卡）｜2. grant key 带 server 维度（`srvA__write` 与 `srvB__write` 不互免）｜3. 重扫释放旧连接（fake `clientFactory` 计数，close 次数 == 旧 face 数）｜4. 起服失败零残留｜5. 幂等（重复 stop / 重扫后再装配）｜6. 既有 `gateway_security_test` / `gateway_per_session_projection_test` / `gateway_server_test` 无回归。

## 5. 验收基线

`export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"` 后：`flutter analyze` → 0 issue；`flutter test --timeout 180s` → 全绿（P0-C 后基线 **717/717**）；`bash scripts/agent-tools/arch-guard.sh` → 0 违规。网关改动属协议/生命周期面，真机冒烟（PC 双连接 + 插件安装触发重扫）留作最终验收。

## 6. 纪律

- 修复期**禁止新增反向边**：`core` 保持零出向（新增 `keyed_write_queue.dart` 只依赖 SDK）。
- 跨域公共签名（`_enqueue`、store 构造）**只增不改**，保持对调用点零破坏（P0-A 裁决 3.3）。
- 每完成一条断言即补 devlog `[变更]` + `[验证]` 成对记账（dev-loop §2）。

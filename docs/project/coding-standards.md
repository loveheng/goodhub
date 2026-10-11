---
status: active
updated: 2026-10-10
---

# GoodHub 编码规范 · 工程落地基准

> 本文对标 architecture.md（ADR-001~005）与 requirements.md 的已定决策，是整个工程编码的**基准规则 SSOT**。冲突裁决：`context/epics/<epic>/memory.md` 显式决策 ＞ 本文 ＞ 通用规约。需求映射：N1、F1.2/F1.7/F1.9/F1.12/F1.13、F4.5/F4.6、§1/§2/§4/§9/§10/§11/§15（architecture.md）。

## 1. 工程拓扑与分层架构（Clean Architecture）

严格**无循环依赖**，分层自底向上依赖；业务逻辑层严禁逆向导入 UI 或平台原生代码。

```text
lib/
├── app/                        # 应用入口、路由、全局配置与依赖注入（平台实现仅在此装配）
│   ├── app.dart
│   └── routes.dart
├── core/                       # 平台无关通用基础设施
│   ├── errors/                 # 异常基类 (McpException, GuardrailException)
│   ├── storage/                # 文件系统统一封装（SequentialFileWriter 等，见 §4.1）
│   ├── network/                # 纯传输底座：HTTP client、重连退避算法（见下方边界纪律）
│   ├── security/               # Keystore/EncryptedStorage 抽象与实现
│   └── telemetry/              # Trace-ID 生成、日志滚动器 (ops.log)
├── platform/                   # 平台适配层（双端纪律 N1）
│   ├── interfaces/             # Dart 纯抽象接口 (Clipboard, Notification, Engine)
│   ├── android/                # Android 平台通道适配 (LlmBridge, Binder 校验)
│   └── ios/                    # iOS Stub 占位（严禁编译报错；CI 断言 flutter analyze 全绿）
├── features/                   # 垂直业务特性切片
│   ├── mcp_bus/                # ① MCP 双工总线 (Client, Server, ToolRouter, JIT)
│   ├── coordinator/            # ② 混合推理编排 (BYOK, 端侧引擎, 熔断网关)
│   ├── skill/                  # ③ 三级 Skill 系统 (CoW 继承, 沙盒)
│   ├── sandbox/                # ④ 记忆沙盒 (memory.md, 串行写队列)
│   ├── aggregator/             # ⑥ 暂存池 ($ref 惰性注水, 权限联合拦截)
│   └── session/                # ⑮ 会话管理 (Trace-ID 穿透队列, 临时会话)
└── ui/                         # ⑤ 控制台与双轨消息流（视觉规范 SSOT 见 ui-design.md）
    ├── theme/                  # 工业控制台主题 (Tokens, Monospace 规范)
    ├── capsule/                # 顶部状态胶囊与 Abort 控制器
    ├── dual_track/             # 双轨消息流 (Markdown 轨 + 操作卡片状态机)
    └── console/                # 服务大厅与 Integration Hub 面板
```

**core/network 与 mcp_bus 的边界纪律**：`core/network` 只放**纯传输底座**（HTTP client、指数退避算法等通用件）；**JSON-RPC/SSE 协议语义必须住在 `features/mcp_bus`**——重连期间「积压队列整体丢弃并回告模型、不静默重放」（F1.12）是总线策略，漏到 core 即围栏旁路。

## 2. 核心编码纪律与硬性规则（Hard Rules）

### 规则 1：双端跨端纪律（N1）

- **禁止平台污染**：`lib/features/` 与 `lib/ui/` 下**绝对禁止** `import 'dart:io'`（文件系统统一走 `core/storage` 或抽象接口），**绝对禁止**导入含 Android/iOS 专有概念的代码。
- **接口驱动**：所有系统特权能力（剪贴板、通知、端侧推理引擎）必须定义纯 Dart 抽象类（`abstract interface class`），平台实现在 `lib/app/` 初始化阶段经依赖注入装配。
- **机械验收**：CI 断言 `flutter analyze` 全绿 + features/ui 目录 grep 无 `dart:io`。

### 规则 2：单 OS 进程与并发调度防死锁

- **单进程硬约束（F4.7 / §11）**：全组件（UI/前台服务/Server 监听）严格单 OS 进程，禁 `:remote`——跨进程并发使串行写队列失效。
- **主 Isolate（UI + State Machine）**：Flutter UI、SessionManager 状态机、`Completer` 串行文件写队列。
- **Worker Isolate（CPU 密集，强制 `compute()` / 专用 Isolate）**：PII 正则脱敏、大 JSONSchema 解析、>1MB 临时文件数据处理——防主线程 ANR。
- **Trace-ID 亲和穿透（§1/§15）**：SessionManager 调度必须显式提取 `Trace-ID`；与当前运行任务同 Trace-ID 且 hop ≤2 的重入请求**直接内联执行，严禁进入阻塞等待队列**。穿透的只是队列，不穿透权限（仍受 hop 硬限与 L1/L2 网关约束）。

### 规则 3：熔断与步数墙语义边界（§2）

- **两步熔断**：同一工具连续 2 次被拒/抛错 → 强中止 + 排查卡片。**管「同一工具连续报错」**。
- **步数墙**：单任务 `max_turns=10`（可配）超限熔断出排查卡。**管「逻辑无错但空转」**——互补不互替。
- **用户主动拒绝不计入熔断计数**：熔断管系统报错，用户纠正是对话的一部分；禁止「用户改两次意见即熔断杀会话」。

## 3. 数据不可变性与状态机规范

- **纯实体与状态**：数据模型统一 `@freezed` 或手写全 `final` 不可变类，禁止可变集合。
- **卡片操作状态机**：操作轨流转用受保护密封类（Sealed Class），不可逆转：

```dart
sealed class ActionCardState {
  const ActionCardState();
}
class ActionCardPending extends ActionCardState { /* ... */ }
class ActionCardRunning extends ActionCardState { final double progress; /* ... */ }
class ActionCardApproved extends ActionCardState { final DateTime approvedAt; /* ... */ }
class ActionCardRejected extends ActionCardState { final String? feedback; /* ... */ }
class ActionCardCancelled extends ActionCardState { /* ... */ }
class ActionCardFailed extends ActionCardState { final String error; /* ... */ }
```

- **Cancelled ≠ Failed（§10 纪律）**：用户 Abort / `$/cancelRequest` 级联终态必须落 `Cancelled`；仅真实错误落 `Failed`。**禁止混用**——审计语义不可逆。
- **Abort 级联固定顺序（§10）**：UI Abort → ① 终止本地 LLM Generator → ② 终结本地执行队列 → ③ 对外部 Server 下发 `$/cancelRequest`（不只断 SSE）→ ④ 卡片终结为 `Cancelled`。实现必须按此顺序，不得乱序/跳步。

## 4. 命名约定与代码风格

- **MCP 命名空间隔离（F1.2）**：工具与路由统一 `<server_id>__<tool_name>`——**双下划线仅作两段分隔符**，各段自身 snake_case（如 `goodshare__list_notes`）；工具名内部禁止再出现双下划线。
- **数据引用前缀（F1.7）**：惰性注水句柄统一 `$ref:<server_id>:<unique_id>`。
- **自定义注解（F1.9）**：对外共享声明统一 `x-` 前缀：`x-mcp-export-to-shared`。
- **文件命名**：小写蛇形（`session_manager.dart` ↔ `SessionManager`），文件名与主要暴露类型严格对应。
- **禁 `dynamic`**：网络层解析完成后第一时间 Schema 转强类型；内部总线管道禁止 `dynamic` 传递。
- **显式错误传递**：统一 `Result<T, McpError>` 包装或领域异常（`core/errors/`），禁止随处裸抛无类型异常。

## 5. 关键设计模式实现基准

### 5.1 文件写安全（File Mutex 降格实现，§4）

单 Isolate 内任务串行锁 + 临时文件原子替换；**接口必须含 `append` 语义与轮转钩子**（memory.md 为全量重写内存态后落盘，ops.log 为追加 + 10MB 单代滚动，F4.6）：

```dart
class SequentialFileWriter {
  final File file;
  Future<void> _lastWrite = Future.value();

  SequentialFileWriter(this.file);

  Future<void> write(String content) => _enqueue(() async {
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(content, flush: true);
        await temp.rename(file.path); // 原子替换
      });

  Future<void> append(String content) => _enqueue(() async {
        await File(file.path).writeAsString(content,
            mode: FileMode.append, flush: true);
      });

  Future<void> _enqueue(Future<void> Function() task) {
    _lastWrite = _lastWrite.then((_) => task());
    return _lastWrite;
  }
}
```

- ops.log 轮转（10MB 上限 + `.1` 单代滚动 + 启动清理）由调用方在 append 链路上检查触发，**轮转本身也必须入队串行执行**。
- 禁止并发裸写磁盘；禁止绕过 writer 直接 `File.writeAsString`。

### 5.2 敏感数据处理（PII Redaction Guardrail，N7 / §2）

发往云端 BYOK 的**全量出站载荷**（用户输入、Resource 读取内容、工具返回值**含特权工具返回值**——剪贴板/记忆）在组装 Payload 阶段必须过脱敏管道；覆盖不全即围栏旁路：

```dart
abstract interface class PiiRedactionPipeline {
  /// Worker Isolate 中执行脱敏；返回清洗后文本 + 反向映射还原字典
  Future<RedactionResult> redactOutbound(String rawText);

  /// 推理返回后反向还原占位符
  String restoreInbound(String text, Map<String, String> tokenMap);
}
```

- 遮蔽失败**拦截请确认，严禁静默放行**（N7）。

## 6. 测试与质量门禁（Quality Gates）

### 6.1 单元测试覆盖要求

- `mcp_bus`：ToolRouter 命名空间隔离、JIT 元工具命中解析。
- `aggregator`：`$ref` 注入生命周期、越权跨 App 隔离拦截。
- `coordinator`：两步熔断、`max_turns=10` 步数墙、**用户拒绝不计入熔断计数**。

### 6.2 死锁防护集成测试

- **Trace-ID 递归重入**：模拟 App A 回调 GoodHub（同 Trace-ID、hop ≤2），验证内联穿透、不因单 Isolate 队列永久挂起。
- **Abort 级联顺序**：验证 §10 四步顺序依次发生且终态为 `Cancelled`（非 `Failed`）。
- **重连不重放**：SSE 断连后积压队列整体丢弃并回告模型，无写操作重放。

### 6.3 内存与泄露审查

- SSE 长连接 `dispose` 时主动关闭。
- `$ref` 临时缓存（含 >1MB 落 cacheDir 文件）在 Session Terminated 时显式物理清理，**须有断言验证**（F4.5 Session 即焚 + TTL 30min + 启动幂等清池）。

## 7. MCP 对 AI 接口契约（Server 角色立法）

> **前提（2026-10-10 用户裁决）**：Server 角色（:8766 对外暴露）暂缓不做，本节约定仅在反向能力重启时生效（形态见 future-considerations.md FC6：服务对象为桌面 AI 平台 / MCP 客户端，桌面平台先记录待完成 → 宿主批量处理，非实时直调）。Client 侧代码当前不受本节约束。
>
> 立法来源：goodshare 仓 `docs/engineering/ai-dev-spec.md` §4「AI 操作者专章」（跨仓只读指针，不复制正文）。

1. **工具描述主动引导**：每个 MCP 工具的 `description` 必须写「怎么用才对」，不只「干什么」——给出推荐用法与反例（如「多步记忆修改优先合并为一次 `update_memory`，勿逐条碎写」）。这是防 AI 低效/危险操作的主动防线；空泛描述（"更新记忆"）不合格。
2. **操作者身份由传输层注入**：调用主体（`local`/`external:<app>`）一律从鉴权层（F1.17 UID 白名单 / Bearer Token）推导，**禁止从请求载荷字段读取**——否则外部 AI 可在 JSON 里自称 `"actor":"local"` 越权。主体 × 工具矩阵在 Server 注册表维护，新增特权工具必须同步矩阵。
3. **写后必回最新快照**：写类工具返回**变更后的最新状态**（与对应读工具同形状），禁止回 void/纯成功文案——调用方（大模型）上下文必须与库内状态对齐；数据移出可见域时显式置空并说明。
4. **错误契约带 hint**：拒绝统一走领域异常（`core/errors/`），`code` 机器可读（`version_conflict`/`permission_denied`/…）；**可纠正分支必须带 `hint`**（告诉调用方下一步该做什么——模型需要向用户解释）；禁止底层异常（IO/平台）裸漏到 MCP 层。与 N7 同口径：遮蔽失败拦截请确认，严禁静默放行。
5. **长窗口读改写必带乐观锁**：「读→推理→写」路径必须携带版本/校验字段（参照接缝契约 `expected_version`），缺失即拒绝或静默覆盖风险自证——Server 侧工具按此立参。

**新增工具自查清单（任一缺失即不合格）**：工具注册（含描述引导）→ 主体矩阵 → 参数 Schema（强类型，禁 `dynamic`）→ 契约测试（`test/`，与 §6 质量门禁同交付线）。

## 8. 与 dev-loop 工程护栏的对齐

两步熔断语义须与全局 dev-loop 护栏 3 对齐口径（architecture.md 待拍板项）——落地时在 epic memory.md 显式登记口径结论。


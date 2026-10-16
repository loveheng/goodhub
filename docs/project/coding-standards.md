---
status: active
updated: 2026-10-16
---

> **名词映射（2026-10-16）**：本文件中的「服务大厅」= 现**设置页**（`lib/ui/settings_page.dart`）——聊天页 ⚙ 设置弹层已并入服务大厅并统一改名「设置」。历史决策/施工原文**保留不替换**，代码与现行文档以新名为准（合并记录见 [page-revamp.md](page-revamp.md)）。

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
    └── console/                # 设置页与 Integration Hub 面板
```

> **现状对照（2026-10-15 对账注记）**：上图是**目标拓扑**；仓库现状是**扁平域目录**——`lib/mcp/`、`lib/coordinator/`、`lib/llm/`、`lib/sandbox/`、`lib/gateway/`、`lib/ui/`、`lib/core/`、`lib/task/`、`lib/update/` + `main.dart`。映射关系：`features/mcp_bus` → `lib/mcp/`（客户端 / 本地插件发现 / 传输 / 探活 / 端点存储）+ `lib/coordinator/tool_router.dart`（ToolRouter 前缀路由，M4-T6）；`features/coordinator` → `lib/coordinator/`（含 Skill 注册表与 `$ref` 暂存池 `ref_store.dart`）；`features/sandbox` → `lib/sandbox/`（记忆 / 会话）；`features/session` → **无独立落点**（会话态散在 `ui/chat_page` + `gateway_server` + `skill_registry`，SessionManager 仲裁已显式关闭，见 architecture.md §15）；**2026-10-16 起由 window-kernel-split 立 `ConversationSession` 内核承接**（落点随步 0 定，见 [`window-kernel-split.md`](../design/window-kernel-split.md) §3.1 / §7.5）；`lib/gateway/`（2026-10-12 网关解冻后新增）与 `lib/update/`（自更新）为拓扑图外的新增域。
>
> **收敛纪律（M4-D4 拍板，2026-10-16 修订）**：新增文件**沿用现状扁平域目录**；在统一收敛拍板之前，禁止单独引入 `features/` 前缀造成双拓扑并存。
>
> **唯一例外（2026-10-16 新增，解 M4-D4 死锁）**：**`lib/app/`（装配容器 / 依赖注入）允许先行建立**，作为目标拓扑的**唯一 seed**。理由：① 规则 1 三处 `dart:io` 的整改触发条件是「`platform/interfaces` 建立」，而该层无人建、无触发条件，死锁；② 「统一收敛拍板」无 owner 无日期，永不到来。二者共享同一个单点解——装配容器。落点与时机见 [`window-kernel-split.md`](../design/window-kernel-split.md) §7.5 步 0-T7。**除 `lib/app/` 外，任何新前缀一律视为双拓扑，禁止**。
>
> **收敛 owner 与触发条件（补 M4-D4 缺口）**：owner = 装配容器首次落地那一轮的实施者；触发条件 = 三处 `dart:io` 豁免清零（见规则 1）**或** 出现第二个需跨窗口共享的应用级内核，届时回本文重评整体拓扑收敛。

### 1.1 窗口层 / 内核层分层纪律（window-kernel-split，2026-10-16 立）

> 内容 SSOT：[`window-kernel-split.md`](../design/window-kernel-split.md)。本节只固化**编码时必守的五条**，细则与内核清单一律查该文，**本文不复制正文**（防双源漂移）。

架构形态 = **两层 + 端口**：**窗口**（投影层，`lib/ui/` 各页 + headless 的 `gateway_controller`）**单向依赖内核**（领域层）；向下传**值对象**（`SessionContext` + 装配选项），向上传**回调端口**（`RuntimeDelegates`，控制反转）。

**形态判据（新增代码必过；用于判「形式合规但实质走偏」）**：① 新消费点**不得就地构造**共享内核——一律取装配容器单一实例；② 新窗口**不得持有领域态**——只持视图态与端口实现；③ 新内核须**先登记生命周期层级**（应用级 / 会话级 / Run 级），**未定层级不得开工**。终态形态与内核清单一律以设计稿为准，本文不列。

1. **内核纯 Dart**：内核文件（`ServiceDirectory` / `McpRuntime` / `ConversationSession` 及后续登记内核）**严禁 import Flutter**（`material.dart` / `BuildContext` / `setState` / `ChangeNotifier`）。内核须可被 headless 路径复用，染 Flutter 即失效。**机械验收**：新增内核文件 grep 无 `package:flutter`。
2. **单一 owner，禁止就地构造**：跨窗口共享的应用级状态（服务目录 / 记忆 / 会话档案等）**只能有一个 owner**，由装配容器供给**单一实例**；消费点**禁止就地 `new` 或自行拼路径**。反例（已产出生产 bug）：`mcp_servers.json` 曾在 3 处各拼一次，`gateway_controller` 那处漏带 `prefs` 迁移 → 旧配置在网关侧读不到。
3. **生命周期单向依赖**：应用级 ← 会话级 ← Run 级，**严禁反向依赖**；短周期消亡不得拉扯长周期实例销毁；长周期变更经**快照 + 端口**下传。**不引事件总线**——总线会把 Run 级生命周期拉成应用级，必然泄漏。
4. **视图态不下沉、领域态不上浮**：双轨渲染模型 / 流控 / 滚动跟随 / CallCard 相位**永远留在窗口**；transcript / 技能激活集 / 降级判据 / 私有域绑定**永远留在内核**。二者同居一个 `State` 是「新增字段要改 3 处、漏改即静默 bug」的根源。
5. **内核命名须登记**：新增内核前先在设计稿 §3.1 内核清单登记，**禁止自造同义名**（已裁决用 `McpRuntime`，不得另写 `ServiceRuntime` / `ServiceManager`）。

### 1.2 core/network 与 mcp_bus 的边界纪律`core/network` 只放**纯传输底座**（HTTP client、指数退避算法等通用件）；**JSON-RPC/SSE 协议语义必须住在 `features/mcp_bus`**——重连期间「积压队列整体丢弃并回告模型、不静默重放」（F1.12）是总线策略，漏到 core 即围栏旁路。

## 2. 核心编码纪律与硬性规则（Hard Rules）

### 规则 1：双端跨端纪律（N1）

- **禁止平台污染**：`lib/features/` 与 `lib/ui/` 下**绝对禁止** `import 'dart:io'`（文件系统统一走 `core/storage` 或抽象接口），**绝对禁止**导入含 Android/iOS 专有概念的代码。
- **接口驱动**：所有系统特权能力（剪贴板、通知、端侧推理引擎）必须定义纯 Dart 抽象类（`abstract interface class`），平台实现在 `lib/app/` 初始化阶段经依赖注入装配。
- **机械验收**：CI 断言 `flutter analyze` 全绿 + `lib/ui/` 目录 grep 无 `dart:io`。
- **2026-10-16 对账：现存三处违规（临时豁免，非免检）**：`lib/ui/chat_page.dart:12`（支持目录）、`lib/ui/settings_page.dart:35`（**行号自 :19 漂移修正**）、`lib/ui/update_page.dart:1`（安装与文件路径）直接 `import 'dart:io'`。**豁免理由**：三处消费的都是平台专属能力，而 `lib/platform/` 抽象层（目标拓扑）尚未建立——在无抽象层时硬套会造出第三处旁路。
- **整改触发条件（2026-10-16 扩展，解死锁）**：① `lib/platform/interfaces`（或等价抽象）建立时；② **或 `lib/app/` 装配容器建立时**（§1 唯一例外）——**二者先到为准**，届时三处必须改为经抽象接口 / 装配容器注入。**在此之前禁止新增第四处违规**。预期顺序：`chat_page.dart:12` 随 window-kernel-split 步 0（`ServiceDirectory` 单一入口 + 装配容器）率先消除。

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

- **Cancelled ≠ Failed（§10 纪律）**：用户 Abort / `notifications/cancelled` 级联终态必须落 `Cancelled`；仅真实错误落 `Failed`。**禁止混用**——审计语义不可逆。
- **Abort 级联固定顺序（§10）**：UI Abort → ① 终止本地 LLM Generator → ② 终结本地执行队列 → ③ 对外部 Server 下发 `notifications/cancelled`（不只断 SSE）→ ④ 卡片终结为 `Cancelled`。实现必须按此顺序，不得乱序/跳步。
- **命名口径（2026-10-15 修正）**：取消通知的 MCP 2025-06-18 规范名是 **`notifications/cancelled`**；`$/cancelRequest` 为早期草案方法名，**代码已于 M3-T2 全量改为前者**，本文残留旧名的两处同步修正——新增注释/文档一律用规范名。
- **状态归属与生命周期（2026-10-16 新增，§1.1 配套）**：**领域态与视图态不得同居一个 `State`**——同一份会话态既要渲染又要入模型，必然退化为「新增字段要改 3 处（声明 / reset / 落盘）、漏改即静默 bug」。新增会话级字段一律落内核并随之持久化，**禁止在窗口 `State` 加裸字段 + 手工枚举 reset**。Run 级资源句柄（连接池 / RefStore / 路由）**随 Run 焚**：`close()` 必须**幂等**且覆盖正常与异常两条路径；窗口**不得缓存 Run 焚后的引用**。

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
- **内核须带注入位 + 装配级测试（2026-10-16 新增）**：新增或搬迁内核时，装配函数**必须接受依赖注入位**（范式：`server_probe.dart` 的 `clientFactory`、`settings_page` 的 `storeOverride` / `probeOverride`）——资源句柄封死后，「连接是否全部 close」**只能靠注入假件计数断言**，无注入位即无从验证；同时补**装配产物等价性**单测（搬迁前后逐项一致），**不得只靠真机冒烟**。

### 6.2 死锁防护集成测试

> **2026-10-15 对账：四项门禁的落地状态**（缺位项已标注归属，未做≠不做，挂 pending-confirm / 各 epic todos 跟踪）：

- [x] **Trace-ID 递归重入**（部分落地）：环检测已落 `lib/gateway/gateway_loop_guard.dart` + 单测 9 例（`test/gateway/gateway_loop_guard_test.dart`）——但形态是**网关入站环路阻断**（`-32000`），规则 2 设想的「同 Trace-ID 且 hop ≤2 的内联穿透、不进阻塞队列」尚未实现（SessionManager 仲裁已显式关闭，见 architecture §15）。**剩余缺口**：真机/集成级的「App A 回调 → 内联执行不挂起」验证，随 SessionManager 解冻同批做。
- [ ] **Abort 级联顺序**：`notifications/cancelled` 下发与 `Cancelled` 终态**代码已落**（M3-T2 + M4-T3），但缺**四步顺序的集成断言**——现仅单测覆盖终态，顺序无机械验证。归属 M4 收官批。
- [ ] **重连不重放**：依赖 M4-T4 连接韧性（心跳/指数退避/积压丢弃回告），**整体未落地**（`lib/` 对 `backoff|reconnect` 零命中），2026-10-15 裁定暂缓至文档收口后启动。
- [x] **`$ref` 物理清理断言**（见 §6.3）：单测已覆盖 Session 即焚 + 启动幂等清池；启动清池已于 2026-10-15 挂进 `main.dart`（此前 API 与单测在但未接启动）。

### 6.3 内存与泄露审查

- SSE 长连接 `dispose` 时主动关闭。
- `$ref` 临时缓存（含 >1MB 落 cacheDir 文件）在 Session Terminated 时显式物理清理，**须有断言验证**（F4.5 Session 即焚 + TTL 30min + 启动幂等清池）——**已闭环（2026-10-15）**：`RefStore.expireAll` 会话即焚 + `sweepStartupOrphans` 挂 `main.dart` 冷启动，单测 `test/coordinator/ref_store_test.dart` 11 例钉住。
- **网关侧新增（2026-10-15）**：SSE 订阅通道与心跳 Timer 在 `stop()` 中显式释放（`gateway_server.dart`）；环路防护的在途 traceId 集合走 `try/finally` 必释 + TTL 300s 惰性驱逐，防长连接强断导致记录泄漏。

## 7. MCP 对 AI 接口契约（Server 角色立法）

> **前提（2026-10-12 解冻，取代 2026-10-10「暂缓不做」裁决）**：Server/Gateway 角色已落地——`:8766/mcp` 对外暴露，形态为**实时聚合网关**（非 FC6 的「桌面平台先记录待完成 → 宿主批量处理」，该形态已被取代，见 future-considerations.md FC6 注记）。**本节自即日起全面生效**，约束对象 = 网关对外可达的工具面（`lib/gateway/` + 经网关聚合的本地 Binder 插件与远端 HTTP server 工具）；不经网关的纯 Client 侧内部工具链不受强制约束，但建议同口径（未来可能随聚合范围扩大而纳入）。
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


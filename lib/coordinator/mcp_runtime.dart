/// MCP 运行时内核契约（window-kernel-split 步 0-T1~T6）。
///
/// **设计 SSOT**：`docs/design/window-kernel-split.md` §7.5 步 0 + §8.1 台账十二项；
/// 任务/门禁/回滚点 = `context/epics/window-kernel-split/plan.md`（本文件不抄任务表）。
///
/// **C1 纯 Dart 纪律**：本文件严禁 import Flutter Widget（`material.dart` /
/// `BuildContext` / `setState`）——内核跨 headless（gateway）复用，染 Widget 即失效。
/// 传递性 `flutter/foundation`（debugPrint）既有件不在此限。
///
/// **步 0 定位**：零接线立契约——`assemble` / `toJson·fromJson` 按裁决
/// 「只立签名、不实现」，其余按 §8.1 已拍板语义可完整实现。
library;

import 'dart:developer' as developer;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'agent_loop.dart';
import 'cow_skill_sync.dart';
import 'cow_sync.dart';
import 'degradation_controller.dart';
import 'discovery_executor.dart';
import 'fenced_cloud_engine.dart' show PiiFenceDelegate;
import 'hybrid_assembly.dart';
import 'local_resource_tool_executor.dart';
import 'local_tool_chain.dart';
import 'memory_tool_executor.dart';
import 'mcp_tool_face.dart';
import 'permission_gateway.dart' show GateDelegate, ToolNotice;
import 'ref_store.dart';
import 'ref_hydrator.dart' show CrossSourceDelegate;
import 'skill_registry.dart';
import 'tool_breaker.dart' show BlockDelegate;
import 'tool_router.dart';
import '../core/errors/mcp_error.dart';
import '../llm/cloud/cloud_llm.dart'
    show CloudChatMessage, CloudLlmEngine, CloudToolSchema;
import '../mcp/connection_manager.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/mcp_client.dart';
import '../llm/cloud/sampling_engine.dart';
import '../mcp/sampling.dart' show SamplingQuota, samplingRequestHandler;
import '../mcp/elicitation.dart'
    show ElicitationDelegate, elicitationRequestHandler;
import '../mcp/server_capabilities.dart';
import '../mcp/server_endpoints.dart';
import '../mcp/server_probe.dart' show McpClientFactory;
import 'reserved_namespace.dart';
import '../resources/resource_store.dart';
import '../sandbox/memory_store.dart';
import '../sandbox/workspace_state_store.dart';
import 'resource_attachment_binder.dart' show ResourceAttachment, bindResourceAttachments;

// ---------------------------------------------------------------------------
// T1 · SessionContext —— 纯不可变快照（§8.1-4：不含配额）
// ---------------------------------------------------------------------------

/// 装配入参快照：窗口收集当前会话状态传入 [McpRuntime.assemble]。
///
/// 纯不可变（深拷贝列表）；**不含 [SamplingQuota]**——配额是跨 Run 共享的
/// 会话级活态，作独立实例入参（§8.1-4），不进快照。
class SessionContext {
  SessionContext({
    this.activePrivateServerId,
    Iterable<String> activatedSkills = const [],
    this.conversationId,
    this.degradation,
    Iterable<CloudChatMessage> transcript = const [],
    this.wsStates,
  })  : activatedSkills = List<String>.unmodifiable(activatedSkills),
        transcript = List<CloudChatMessage>.unmodifiable(transcript);

  /// 私有域绑定三态：null=未绑定（走回退链）/ ''=显式公共 / id=锁定（D-C）。
  final String? activePrivateServerId;

  /// 已激活 Skill 名集（§15：激活集属会话）。
  final List<String> activatedSkills;

  /// 当前会话 id（未建会话为 null）。
  final String? conversationId;

  /// 降级判据（可变控制器按引用传递——快照语义收敛在值字段，见 §8.1-4）。
  final DegradationController? degradation;

  /// 上轮 transcript（D11 续接源；[ConversationSession.replaceTranscript] 的读取面）。
  final List<CloudChatMessage> transcript;

  /// 会话级事实库（P2-6；null = 未懒建）。
  final WorkspaceStateStore? wsStates;
}

// ---------------------------------------------------------------------------
// T3 · RuntimeDelegates —— 八端口（§8.1-8：挂起 Future / 广播 void 两类）
// ---------------------------------------------------------------------------

/// 连接回告类别（工厂构造非类型，模式匹配走 [ConnectionReport.kind]）。
enum ConnectionReportKind { disconnect, backlog, resourceUpdated }

/// 连接回告（广播端口 `connectionReport` 的载荷，§7.1 #3）。
class ConnectionReport {
  const ConnectionReport.disconnect({required this.inFlightCancelled})
      : kind = ConnectionReportKind.disconnect,
        droppedCount = 0,
        uri = null;

  /// 重连成功但积压丢弃。
  const ConnectionReport.backlog({required this.droppedCount})
      : kind = ConnectionReportKind.backlog,
        inFlightCancelled = 0,
        uri = null;

  /// resources/updated：资源已陈旧。
  const ConnectionReport.resourceUpdated(this.uri)
      : kind = ConnectionReportKind.resourceUpdated,
        inFlightCancelled = 0,
        droppedCount = 0;

  final ConnectionReportKind kind;

  /// 断连：在途已取消数（不重放语义由连接层保证）。
  final int inFlightCancelled;

  /// 积压丢弃数。
  final int droppedCount;
  final String? uri;
}

/// 装配端口组（§7.1 表 + 步 1 补记第 9 广播）。`onToolCall` **不在内**——它是
/// 执行期事件流消费（`await for (loop.run(...))`），属窗口渲染，塞进来会扩大
/// 搬迁边界。
///
/// 两类约束（§8.1-8）：
/// - **挂起**（`Future<T>`，Human-In-The-Loop，内核 `await`）：
///   gate / fence / block / consent / majorJump；
/// - **广播**（`void`，火即忘，内核不得 await）：
///   onNote / onProgress / onNotice / connectionReport。
///
/// **第 9 广播 `onNotice`（步 1 迁移发现，回写设计稿 §7.1 表）**：
/// `PermissionGateway.onNotice` 是 L1 放行 / 会话豁免的**状态带+触感**通告，
/// 触发时机不与 confirm() 重合（每次 L1 执行即发），无法并入 gate 挂起端口，
/// 语义上属 onProgress 同族（状态带反馈）——独立成口，9 个在「8→10+ 复议」
/// 容差内。
///
/// **`gateDelegate` 可空**（§8.1-2）：headless 传 null → `PermissionGateway`
/// 既有 fail-closed（L2 恒 `user_rejected`，模型可自纠）。**禁止**在 delegate
/// 内做只读自动放行（无只读判据，会造第二判定源）。
class RuntimeDelegates {
  const RuntimeDelegates({
    this.gateDelegate,
    this.fenceDelegate,
    this.blockDelegate,
    this.consentDelegate,
    this.majorJumpDelegate,
    this.elicitationDelegate,
    this.onNote,
    this.onProgress,
    this.onNotice,
    this.connectionReport,
  });

  // —— 挂起（Future<T>）——

  /// L2 确认卡（chat `_ChatGate`；null = headless fail-closed）。
  final GateDelegate? gateDelegate;

  /// N7 围栏拦截卡（chat `_ChatFence`；null = 无人值守 fail-closed）。
  final PiiFenceDelegate? fenceDelegate;

  /// 熔断/步数墙排查卡（chat `_ChatBlock`）。
  final BlockDelegate? blockDelegate;

  /// D5 跨源授权（恒 L2 弹卡、无豁免勾选）。
  final CrossSourceDelegate? consentDelegate;

  /// CoW 大版本跃迁确认。
  final CowMajorJumpDelegate? majorJumpDelegate;

  /// elicitation 交互卡委托（server→宿主结构化提问；null = 无人值守 decline）。
  final ElicitationDelegate? elicitationDelegate;

  // —— 广播（void）——

  /// 轨迹/告警注记（对应 chat `_add(TrackNote)`；danger=true 红字）。
  final void Function(String message, {bool danger})? onNote;

  /// 状态带工具进度（对应 `_setPill` + `loop.emitToolProgress` 桥接）。
  final void Function(String tool, num progress, num? total, String? message)?
      onProgress;

  /// 网关通告（L1 放行 / 会话豁免：状态带 + 触感，§7.1 步 1 补记第 9 广播）。
  final void Function(ToolNotice notice)? onNotice;

  /// 断连 / 积压 / 资源变更回告（对应 `_startConnection` 三回调）。
  final void Function(ConnectionReport report)? connectionReport;
}

// ---------------------------------------------------------------------------
// T5 · McpAssembly —— assemble 出参句柄（§8.1-3/7：两段生命周期 + 幂等 close）
// ---------------------------------------------------------------------------

/// Run 级装配句柄：`loop` / `router` **仅在 [close] 前有效**（Run 焚后悬空，
/// 窗口不得缓存）；连接与 RefStore 封死不外泄。
///
/// 生命周期两段（§8.1-7）：
/// - [abort] 只中断在途、**不释放**（可重复调用、同步完成）；
/// - [close] 才释放且**幂等**（内部 `_closed`，先 abort 再释放）。
///
/// **T4 Abort 兜底（防悬挂）**：Abort 路径须以
/// `GateDecision(approved: false, reason: 'aborted')` 完成**所有** pending
/// 确认卡（`TrackConfirm.completer` 无超时路径，漏兜底即永挂）——该兜底在
/// 窗口侧 Abort 级联实现（步 1 搬迁接线点），内核只保证 [abort] 同步遍历取消。
class McpAssembly {
  McpAssembly._({
    required this.loop,
    required this.router,
    required this.refStore,
    required Map<String, String> serverSummaries,
    required List<McpToolFace> faces,
    required List<McpConnection> connections,
    this.resourceContextFooter,

    /// 借用面监听器（装配层合一 · Contract 件）：close 只摘监听不关 client
    /// （client 归共享能力源所有）；abort 不遍历借用面（跨消费者取消风险）。
    Map<McpToolFace, ToolProgressCallback> borrowedListeners = const {},
  })  : _faces = List<McpToolFace>.unmodifiable(faces),
        _borrowedListeners = Map.of(borrowedListeners),
        _connections = List<McpConnection>.unmodifiable(connections),
        serverSummaries = Map<String, String>.unmodifiable(serverSummaries);

  final AgentLoop loop;
  final ToolRouter router;

  /// 资源附件上下文块（M1-T3）：装配期绑定产物，窗口拼进 userPrompt 前部；
  /// null = 本轮无附件（或 store 未注入）。
  final String? resourceContextFooter;

  /// 服务摘要快照（`<id> → 'Name Tier n'`）：窗口合成「## 已挂载服务」段用
  /// （值快照非活引用，Run 内不变）。
  final Map<String, String> serverSummaries;

  /// 内部闭环（§8.1-3）：abort 遍历**全部** face 取消在途——不依赖「当前哪个
  /// face 在跑」的偶然性（现 `chat_page:959` 取 `faces[serverIds.first]`）。
  final List<McpToolFace> _faces;
  final List<McpConnection> _connections;

  /// 借用面 → 本会话进度监听器（Contract 件）：close 摘除；client 归源。
  final Map<McpToolFace, ToolProgressCallback> _borrowedListeners;

  /// Run 级（§9：Session 结束直清临时文件；refStore 封死不外泄）。
  final RefStore refStore;

  bool _closed = false;

  /// 中断在途（同步完成、可重复）：遍历全部 face 发 cancel notify +
  /// `loop.abort()`。实现约束（T5a）：`cancelActiveRequest` 返回 **void**
  /// （内部 unawaited，禁 await/Future.wait）；`AgentLoop.abort()` **无参**，
  /// [reason] 只用于 cancel notify。
  void abort({required String reason}) {
    if (_closed) return;
    for (final f in _faces) {
      f.cancelActiveRequest(reason: reason);
    }
    loop.abort();
  }

  /// 释放（**幂等**，多次调用仅首次生效）：abort → `connections.stop()` →
  /// `client.close()`（T5b：stop 不关底层传输，此为既有债，随步 1 搬迁一并
  /// 修正）→ `refStore.expireAll()/dispose()`。内部失败 DEGRADE 留痕、
  /// **不抛穿 finally**。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    abort(reason: 'closed');
    for (final c in _connections) {
      try {
        c.stop();
      } on Object catch (e) {
        developer.log('[DEGRADE] mcp-runtime: connection.stop failed: $e');
      }
    }
    // 借用面（Contract 件）：只摘本会话监听器，**不 close**——client 归共享
    // 能力源所有，源侧（GatewayController）统一管理释放。
    for (final entry in _borrowedListeners.entries) {
      try {
        entry.key.removeProgressListener(entry.value);
      } on Object catch (e) {
        developer.log(
            '[DEGRADE] mcp-runtime: borrowed listener remove failed: $e');
      }
    }
    for (final f in _faces) {
      try {
        f.client.close();
      } on Object catch (e) {
        developer.log('[DEGRADE] mcp-runtime: client.close failed: $e');
      }
    }
    try {
      await refStore.expireAll();
      refStore.dispose();
    } on Object catch (e) {
      developer.log('[DEGRADE] mcp-runtime: refStore release failed: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// T5c · McpRuntime —— 装配入口（步 0 立签名，步 1 搬迁后实现）
// ---------------------------------------------------------------------------

/// 挂载原语出参句柄（步 2 装配原语；类型别名须在顶层，不可嵌套类内）。
///
/// **2026-10-17 P0-B 增 [close]**：此前两个挂载原语只回 `face/caps/schemas`，
/// **没有任何释放通道**——`mountEndpoint` 内部建的 client 调用方拿不到引用，
/// 网关重扫/停服无从关闭，每次包变更广播触发重扫就泄漏一批（Binder
/// EventChannel / HTTP 连接池）。挂载原语自此必须交出释放能力。
typedef McpMount = ({
  McpToolFace face,
  ServerCapabilities caps,
  List<CloudToolSchema> schemas,

  /// 释放本次挂载占用的传输资源（幂等；失败由调用方按 DEGRADE 口径收尾）。
  void Function() close,
});

/// MCP 侧 Run 级装配（§3.3 命名裁决：McpRuntime，不用 ServiceRuntime——云端
/// 引擎侧 Run 级装配已由 `hybrid_assembly.dart` 承载）。
class McpRuntime {
  const McpRuntime();

  /// 装配（§8.1-3）：`chat_page._send` 装配段（原 658-970）步 1 搬迁至此。
  ///
  /// - [context]：会话快照入参（T1；degradation 供引擎装配）；
  /// - [endpoints]：**已过挂载位过滤**（enabled=true）的手填 HTTP 端点；
  /// - [locals]：**已过信任闸门**的本地插件（信任卡片是 UI——窗口先裁，
  ///   内核只挂载，避免为信任再造第 10 个端口）；
  /// - [apiKeyReader]：Directory 令牌读取注入（生产 = `epStore.apiKey` tearoff）；
  /// - [memoryStore] / [skills]：装配入参（§3.1 防误读：依赖其接口，不改其内部）；
  /// - [delegates]：端口组（T3 + onNotice）；
  /// - [onSamplingBegin] / [onSamplingEnd]：执行期 stuck 判定钩子（同 `onToolCall`
  ///   原则属窗口，StuckWatcher 由窗口持有，内核只包裹 sampling 在途）；
  /// - [quota]：实例独立入参（T2 / §8.1-4）——chat 传 Session 持有实例，
  ///   null = 内部 new（gateway 现状语义）；
  /// - [clientFactory]：注入位（T5c，范式 `server_probe.dart:49-52`），
  ///   默认 `McpClient.http`。
  Future<McpAssembly> assemble({
    required SessionContext context,
    required List<ServerEndpoint> endpoints,
    required List<LocalPluginInfo> locals,
    required Future<String?> Function(String serverId) apiKeyReader,
    required MemoryStore memoryStore,
    required SkillRegistry skills,
    RuntimeDelegates delegates = const RuntimeDelegates(),
    SamplingQuota? quota,
    McpClientFactory? clientFactory,
    void Function()? onSamplingBegin,
    void Function()? onSamplingEnd,
    CloudLlmEngine? engine,
    Future<Directory> Function()? tempDirResolver,
    Future<Directory> Function()? documentsDirResolver,

    /// 资源中心附件（M1-T3）：非空且 [resourceStore] 就绪时，装配期把全文
    /// 落 run 级 $ref 池并产出上下文 footer（[McpAssembly.resourceContextFooter]）。
    List<ResourceAttachment> resourceAttachments = const [],

    /// 测试注入位 / 生产由窗口经 lib/app 装配传入；null = 不注册本地资源工具面。
    ResourceStore? resourceStore,

    /// 共享能力源 face 表（装配层合一 · Contract 件，2026-10-23 方向裁决）：
    /// 生产由 chat 传 `GatewayController.shared.faces`——id 命中即**借用**该
    /// face（跳过新建/协商/连接，消同源双实例双冷启动），进度经运行期监听器
    /// 接入本会话；client 归源所有，本会话不 close、不入 abort（跨消费者取消
    /// 风险），sampling/elicitation/CoW 接线保留源侧现状。缺省空表 = 旧路径
    /// 全量自建（测试隔离不受影响）。
    Map<String, McpToolFace> sharedFaces = const {},
  }) async {
    // 装配中途失败（如第 N 个端点 negotiate 抛）：回收已建连接/客户端/RefStore
    // 再上抛——原 chat_page 实现里这些资源都在 _send 的 try-finally 保护下，
    // 内核化后该保护必须随装配段一起迁入（plan 步 1 单测「装配异常路径」）。
    final partialConns = <McpConnection>[];
    final partialClients = <McpClient>[];
    RefStore? partialRefStore;
    try {
      return await _assembleInner(
        context: context,
        endpoints: endpoints,
        locals: locals,
        apiKeyReader: apiKeyReader,
        memoryStore: memoryStore,
        skills: skills,
        delegates: delegates,
        quota: quota,
        clientFactory: clientFactory,
        onSamplingBegin: onSamplingBegin,
        onSamplingEnd: onSamplingEnd,
        engine: engine,
        tempDirResolver: tempDirResolver,
        documentsDirResolver: documentsDirResolver,
        resourceAttachments: resourceAttachments,
        resourceStore: resourceStore,
        sharedFaces: sharedFaces,
        partialConns: partialConns,
        partialClients: partialClients,
        partialRefStore: (rs) => partialRefStore = rs,
      );
    } on Object {
      for (final c in partialConns) {
        try {
          c.stop();
        } on Object catch (e) {
          developer.log('[DEGRADE] mcp-runtime: partial conn.stop failed: $e');
        }
      }
      for (final c in partialClients) {
        try {
          c.close();
        } on Object catch (e) {
          developer.log('[DEGRADE] mcp-runtime: partial client.close failed: $e');
        }
      }
      try {
        await partialRefStore?.expireAll();
        partialRefStore?.dispose();
      } on Object catch (e) {
        developer.log('[DEGRADE] mcp-runtime: partial refStore release failed: $e');
      }
      rethrow;
    }
  }

  Future<McpAssembly> _assembleInner({
    required SessionContext context,
    required List<ServerEndpoint> endpoints,
    required List<LocalPluginInfo> locals,
    required Future<String?> Function(String serverId) apiKeyReader,
    required MemoryStore memoryStore,
    required SkillRegistry skills,
    required RuntimeDelegates delegates,
    required SamplingQuota? quota,
    required McpClientFactory? clientFactory,
    required void Function()? onSamplingBegin,
    required void Function()? onSamplingEnd,
    required CloudLlmEngine? engine,
    required Future<Directory> Function()? tempDirResolver,
    required Future<Directory> Function()? documentsDirResolver,
    required List<ResourceAttachment> resourceAttachments,
    required ResourceStore? resourceStore,
    required Map<String, McpToolFace> sharedFaces,
    required List<McpConnection> partialConns,
    required List<McpClient> partialClients,
    required void Function(RefStore refStore) partialRefStore,
  }) async {
    final factory = clientFactory ??
        ((String endpoint, String? apiKey) =>
            McpClient.http(baseUrl: endpoint, apiKey: apiKey));
    final note = delegates.onNote;
    final faces = <String, McpToolFace>{};
    final clients = <String, McpClient>{};
    final summaries = <String, String>{};
    final serverCaps = <String, ServerCapabilities>{};
    final connections = <String, McpConnection>{};
    AgentLoop? loopBox;

    // —— 装配层合一（Contract 件）借用登记：借用面入 faces/summaries（参与
    // 路由与目录），**不入** partialClients/partialConns（失败清理不碰源侧
    // client）、**不入** McpAssembly._faces（close 不关、abort 不取消——共享
    // client 上可能有其他消费者的在途请求，跨消费者取消是踩踏）。sampling/
    // elicitation/CoW 挂 clients 表，借用面不入表 = 保留源侧既有接线。
    final borrowedListeners = <McpToolFace, ToolProgressCallback>{};
    Future<void> borrowShared(
        String serverId, McpToolFace shared, String summary) async {
      if (shared.cachedSchemas.isEmpty) await shared.listTools();
      faces[serverId] = shared;
      summaries[serverId] = summary;
      void listener(String tool, num progress, num? total, String? message) {
        loopBox?.emitToolProgress(tool, progress, total, message);
        delegates.onProgress?.call(tool, progress, total, message);
      }
      shared.addProgressListener(listener);
      borrowedListeners[shared] = listener;
    }

    // —— T6-2 多连接池：每个端点一个 client + face（协商 + 能力目录）——
    for (final ep in endpoints) {
      // 共享能力源命中 → 借用（Contract 件）：跳过新建/协商/连接。
      final shared = sharedFaces[ep.id];
      if (shared != null) {
        await borrowShared(ep.id, shared, '${ep.name} (共享能力源)');
        continue;
      }
      final key = await apiKeyReader(ep.id);
      final client = factory(ep.endpoint, key);
      // 保留命名空间断言（#15）：手填端点声明 `host` → 拒装（宁缺勿炸，
      // 不因一条误配端点炸掉整轮聊天装配）。
      try {
        assertServerIdMountable(ep.id, client);
      } on ReservedNamespaceException catch (e) {
        note?.call('⚠ 端点 ${ep.id} 挂载被拒: ${e.message}', danger: true);
        client.close();
        continue;
      }
      client.samplingEnabled = true; // 托管 server：声明 sampling（§3.11 消费面）
      final caps = await client.negotiate();
      serverCaps[ep.id] = caps;
      note?.call(
        '✓ 已连接 ${ep.name}'
        '${caps.serverVersion != null ? ' v${caps.serverVersion}' : ''}',
        danger: false,
      );
      final face = McpToolFace(
        client: client,
        serverId: ep.id,
        opsLog: memoryStore, // N4 审计（remote 侧）
        onProgress: (tool, progress, total, message) {
          loopBox?.emitToolProgress(tool, progress, total, message);
          delegates.onProgress?.call(tool, progress, total, message);
        },
      );
      await face.listTools();
      faces[ep.id] = face;
      clients[ep.id] = client;
      partialClients.add(client);
      final conn = _startConnection(ep.id, client, face, delegates);
      connections[ep.id] = conn;
      partialConns.add(conn);
      summaries[ep.id] =
          '${caps.serverName ?? ep.name} ${caps.isTier1 ? 'Tier 1' : 'Tier 2'}';
    }

    // —— T-trans-4：本地插件自动挂载（信任闸门已由窗口裁决）——
    for (final info in locals) {
      if (info.serverId.isEmpty || faces.containsKey(info.serverId)) continue;
      // 共享能力源命中 → 借用（Contract 件）：同端点口径。
      final shared = sharedFaces[info.serverId];
      if (shared != null) {
        await borrowShared(
            info.serverId, shared, '${info.serverTitle} (本地·共享能力源)');
        continue;
      }
      try {
        final client = localPluginDiscovery.createClient(info);
        assertServerIdMountable(info.serverId, client);
        client.samplingEnabled = true; // 托管 server：声明 sampling（§3.11 消费面）
        final caps = await client.negotiate();
        serverCaps[info.serverId] = caps;
        final face = McpToolFace(
          client: client,
          serverId: info.serverId,
          opsLog: memoryStore,
          onProgress: (tool, progress, total, message) {
            loopBox?.emitToolProgress(tool, progress, total, message);
            delegates.onProgress?.call(tool, progress, total, message);
          },
        );
        await face.listTools();
        faces[info.serverId] = face;
        clients[info.serverId] = client;
        partialClients.add(client);
        final conn = _startConnection(info.serverId, client, face, delegates);
        connections[info.serverId] = conn;
        partialConns.add(conn);
        summaries[info.serverId] =
            '${caps.serverName ?? info.serverTitle} (本地) ${caps.isTier1 ? 'Tier 1' : 'Tier 2'}';
        note?.call(
          '✓ 本地插件 ${info.serverTitle} ${caps.serverName ?? '?'} ｜ 自动挂载',
          danger: false,
        );
      } catch (e) {
        note?.call('⚠ 本地插件 ${info.serverTitle} 挂载失败: $e', danger: true);
      }
    }

    // —— T6：路由注册表 + 默认激活全部已挂载（保单服务回归）；tier 注入——
    // private 端点进单一私有槽位模型。本地插件（自动挂载）同属「私有 tier」：
    // 挂载方式（自动/手动）只是接入差异，权限隔离（单槽互斥）一视同仁——故一并
    // 进 privateServerIds，不进 activatedServers 默认激活，须被单槽门控（MO：
    // 私有≠免隔离）。
    final localPrivateIds = <String>{
      for (final lp in locals) if (lp.serverId.isNotEmpty) lp.serverId,
    };
    final router = ToolRouter(
      faces: faces,
      privateServerIds: {
        for (final ep in endpoints)
          if (ep.tier == ServerPrivacyTier.private) ep.id,
        ...localPrivateIds,
      },
    );
    router.activatedServers.addAll(
      router.serverIds.where((id) => !router.privateServerIds.contains(id)),
    );
    // 会话绑定（v1）：本会话锁定的私有服务——未显式绑定则按默认回退
    // （全局钉选 isDefault → 首个启用的 private → null）。
    router.activePrivateServerId =
        resolveBinding(endpoints, bound: context.activePrivateServerId);

    // 断连联动（prompt-mgmt §8.2.1）：掉线的是当前激活私有服务 → 只写
    // pending 降级标记，Run 边界（ChatRunOrchestrator.plan）统一收敛生效，
    // 正在执行的 Run 快照不受影响。连接建于 router 之前（_startConnection 无
    // router 可见性），故在 router 就绪后包一层回告（保留原 connectionReport
    // 广播语义，不替换 _startConnection 已挂的闭包）。
    for (final entry in connections.entries) {
      final prev = entry.value.onDisconnectReport;
      entry.value.onDisconnectReport = (r) {
        router.markPrivateServerOffline(entry.key);
        prev?.call(r);
      };
    }

    final refStore = RefStore(
      cacheDir: await (tempDirResolver ?? getTemporaryDirectory)(),
      gcInterval: null, // 短会话，close 即焚
    );
    partialRefStore(refStore);
    // —— 本机工具执行链（T6 链路序唯一 owner = local_tool_chain.dart；
    // #18 体量治理：抽走后 assemble 只留调用）——
    final chain = composeLocalToolChain(
      connections: connections,
      router: router,
      summaries: summaries,
      skills: skills,
      memoryStore: memoryStore,
      refStore: refStore,
      resourceStore: resourceStore,
      gateDelegate: delegates.gateDelegate,
      consentDelegate: delegates.consentDelegate,
      onNotice: delegates.onNotice,
      onNote: note,
    );
    final executor = chain.executor;
    final gateway = chain.gateway;
    final resourceToolStore = resourceStore;
    gateway.loadCatalog([
      ...router.focusedSchemas(),
      ...MemoryToolExecutor.toolSchemas(),
      if (resourceToolStore != null) ...LocalResourceToolExecutor.toolSchemas(),
    ]);
    // 资源附件绑定（M1-T3）：全文落 run 级 $ref 池 + 产出上下文 footer。
    String? resourceContextFooter;
    if (resourceAttachments.isNotEmpty && resourceStore != null) {
      resourceContextFooter = await bindResourceAttachments(
        resourceStore,
        refStore,
        resourceAttachments,
      );
    }

    final effectiveEngine = engine ??
        await assembleDefaultHybridEngine(
          controller: context.degradation ?? DegradationController(),
          piiFenceDelegate: delegates.fenceDelegate, // D4 有人值守拦截卡（可空）
          onNote: note, // P2-1：BYOK 读取失败的用户可见通道
        );
    note?.call('✓ 引擎就绪：${effectiveEngine.name}', danger: false);

    // —— T6：每个 client 接管自身采样反向请求（serverKey = serverId；
    // stuck 判定钩子由窗口注入，顺延判定语义见 StuckWatcher）——
    final effectiveQuota = quota ?? SamplingQuota();
    for (final entry in clients.entries) {
      final sampling = samplingRequestHandler(
          engine: CloudSamplingEngine(effectiveEngine),
          quota: effectiveQuota,
          serverKey: entry.key);
      entry.value.onServerRequest = (method, params) {
        onSamplingBegin?.call();
        return sampling(method, params).whenComplete(() => onSamplingEnd?.call());
      };
    }
    // —— T6：elicitation 反向请求（server→宿主结构化提问）；仅当装配层注入了
    // 委托（有人值守 UI）时声明能力并接线，否则保持 false（无委托 → decline）。
    final elicitation = delegates.elicitationDelegate;
    if (elicitation != null) {
      for (final entry in clients.entries) {
        entry.value.elicitationEnabled = true;
        entry.value.onElicitation =
            elicitationRequestHandler(delegate: elicitation);
      }
    }

    // —— T6：逐 server CoW 同步（有 prompts 能力者）；skill 名保持
    // cow/<promptName>，撞名跳过并通告用户（design 口径）——
    // 注入语义独立成件（#18 体量治理）：`cow_skill_sync.dart`。
    await syncCowSkillsIntoRegistry(
      clients: clients,
      serverCaps: serverCaps,
      skills: skills,
      documentsDirResolver:
          documentsDirResolver ?? getApplicationDocumentsDirectory,
      majorJumpDelegate: delegates.majorJumpDelegate,
      note: note,
    );


    final loop = AgentLoop(
      engine: effectiveEngine,
      executor: executor,
      blockDelegate: delegates.blockDelegate,
      refStore: refStore,
      refServerId: router.serverIds.isNotEmpty
          ? router.serverIds.first
          : 'goodshare',
      serverResolver: router.serverFor,
      // 切域事务提交点（prompt-mgmt §8.2.2）：ToolResultMessage 落历史后提交
      // pending 槽位请求——前 Abort 槽位不变，后 Abort 不回滚。
      onRoundCommitted: router.commitPendingSlot,
      toolsProvider: () => [
        ...router.focusedSchemas(),
        ...DiscoveryExecutor.staticSchemas(),
        skills.activationToolSchema(),
        ...MemoryToolExecutor.toolSchemas(),
        if (resourceStore != null) ...LocalResourceToolExecutor.toolSchemas(),
      ],
    );
    loopBox = loop;
    return McpAssembly._(
      loop: loop,
      router: router,
      refStore: refStore,
      serverSummaries: summaries,
      resourceContextFooter: resourceContextFooter,
      // 借用面（Contract 件）不入 _faces：abort 不取消、close 不关 client
      // （共享 client 上可能有其他消费者在途请求，跨消费者操作是踩踏）。
      faces: [
        for (final e in faces.entries)
          if (!borrowedListeners.containsKey(e.value)) e.value,
      ],
      connections: connections.values.toList(),
      borrowedListeners: borrowedListeners,
    );
  }

  /// 步 1-T2 自 `chat_page._startConnection` 迁入：建韧性连接，断连/积压/
  /// 资源变更三类回告接线 `connectionReport` 端口（广播，内核不 await）。
  McpConnection _startConnection(
    String serverId,
    McpClient client,
    McpToolFace face,
    RuntimeDelegates delegates,
  ) {
    final conn = McpConnection(
      client: client,
      face: face,
      serverId: serverId,
      isAlive: () => face.hasRecentStreamActivity,
    )
      ..onDisconnectReport = (r) {
        delegates.connectionReport
            ?.call(ConnectionReport.disconnect(inFlightCancelled: r.inFlightCancelled));
      }
      ..onBacklogReport = (r) {
        delegates.connectionReport
            ?.call(ConnectionReport.backlog(droppedCount: r.droppedCount));
      }
      ..onResourceUpdated = (uri) {
        delegates.connectionReport?.call(ConnectionReport.resourceUpdated(uri));
      };
    conn.start();
    return conn;
  }

  // -------------------------------------------------------------------------
  // 步 2 · 挂载原语（§7.5 步 2：三处窗口调用点重复的装配胶水收敛于此）
  // -------------------------------------------------------------------------

  /// 挂载原语：`client → negotiate → face → listTools`——原 chat_page /
  /// gateway_controller / 联调页三处重复的这段。步 1 后 chat 走 [assemble]
  /// （内部同一套链路）；gateway / 联调页直接复用本原语，**不开特权分支**
  /// （§8.1-11）。negotiate 有 client 实例缓存，重复取不增 RPC。
  ///
  /// client 由调用方创建并持有：调用方须经 [release] 把「关掉这个 client」的
  /// 能力一并交回（否则句柄表拿不到释放通道——P0-B 泄漏根因）。本原语自身
  /// 不 close（gateway 单源挂载失败需按自身 DEGRADE 口径收尾）。
  Future<McpMount> mount({
    required String serverId,
    required McpClient client,
    MemoryStore? opsLog,
    ToolProgressCallback? onProgress,
    void Function()? release,
  }) async {
    // 保留命名空间断言先行（#15）：撞 `host` 保留 serverId 的外部服务在协商前拒装。
    assertServerIdMountable(serverId, client);
    // 托管挂载原语：声明 sampling capability（§3.11）——gateway / 联调页 /
    // mountEndpoint 均经此，其调用方随后接采样 handler；诊断探针不走此原语故不声明。
    client.samplingEnabled = true;
    final caps = await client.negotiate();
    final face = McpToolFace(
      client: client,
      serverId: serverId,
      opsLog: opsLog,
      onProgress: onProgress,
    );
    final schemas = await face.listTools();
    return (
      face: face,
      caps: caps,
      schemas: schemas,
      close: release ?? _noopRelease,
    );
  }

  static void _noopRelease() {}



  /// 端点挂载原语（§7.5 步 2-3）：按 [ServerEndpoint] 建 HTTP client 并挂载。
  /// 本原语**拥有**它创建的 client：挂载失败即 close 再上抛（调用方无须也无从
  /// 持 client 引用）。
  ///
  /// - 手填端点：key 经 [apiKeyReader]（Directory 安全存储）读取；
  /// - ephemeral 端点（任务侧，§8.1-9）：key 走 [ServerEndpoint.ephemeralKey]
  ///   内存传递，不进 Directory 列表、不参与 `store.save()`。
  Future<McpMount> mountEndpoint(
    ServerEndpoint ep, {
    MemoryStore? opsLog,
    ToolProgressCallback? onProgress,
    McpClientFactory? clientFactory,
    Future<String?> Function(String serverId)? apiKeyReader,
  }) async {
    final key = ep.ephemeralKey ??
        (apiKeyReader != null ? await apiKeyReader(ep.id) : null);
    final client =
        (clientFactory ?? (u, k) => McpClient.http(baseUrl: u, apiKey: k))(
            ep.endpoint, key);
    try {
      final m = await mount(
          serverId: ep.id, client: client, opsLog: opsLog, onProgress: onProgress);
      // 本原语拥有 client → 交出释放闭包（P0-B：否则调用方无从关闭）
      return (face: m.face, caps: m.caps, schemas: m.schemas, close: client.close);
    } on Object {
      try {
        client.close();
      } on Object catch (e) {
        developer.log('[DEGRADE] mcp-runtime: mountEndpoint client.close failed: $e');
      }
      rethrow;
    }
  }
}

// ---------------------------------------------------------------------------
// T6 · ConversationSession —— 会话活态写回契约（§8.1-1；步 3 接线）
// ---------------------------------------------------------------------------

/// 会话活态（会话级 · 跨 Run 存续）：窗口是它的投影，写回只走本类三个方法
/// （§8.1-1，不新增端口）。
class ConversationSession {
  ConversationSession({SamplingQuota? samplingQuota})
      : samplingQuota = samplingQuota ?? SamplingQuota();

  /// 配额归 Session（§8.1-4）：60 分钟窗口跨 Run 共享，是**会话级**不是 Run 级；
  /// **切会话即重置** = 行为变更（原 `chat_page:104` 页面级「重启清零」），
  /// 入步 3 显式验收。
  final SamplingQuota samplingQuota;

  String? _activePrivateServerId;
  final List<CloudChatMessage> _transcript = [];

  // —— 会话级活态（步 3-T4 自 chat_page 五字段收编；懒建由窗口绑定）——
  SkillRegistry? _skills;
  DegradationController? _degradation;
  WorkspaceStateStore? _wsStates;

  /// 三态：null=未绑定 / ''=显式公共 / id=锁定。
  String? get activePrivateServerId => _activePrivateServerId;

  /// 只读视图；写回唯一通道 = [replaceTranscript]。
  List<CloudChatMessage> get transcript => List.unmodifiable(_transcript);

  /// 会话粒度 SkillRegistry（§15：激活集跨 Run 保留；新会话 = 新实例 = 重开）。
  SkillRegistry? get skills => _skills;

  /// 降级判据记忆（会话级）。
  DegradationController? get degradation => _degradation;

  /// 会话级事实库（P2-6；懒建绑定）。
  WorkspaceStateStore? get wsStates => _wsStates;

  void bindSkills(SkillRegistry registry) => _skills = registry;

  void bindDegradation(DegradationController controller) =>
      _degradation = controller;

  void bindWsStates(WorkspaceStateStore store) => _wsStates = store;

  /// **全量替换**（非 append！）：对应原 `chat_page` 事件循环的
  /// `clear() + addAll()`——命名成 append 会致 transcript 跨轮翻倍。
  void replaceTranscript(Iterable<CloudChatMessage> transcript) {
    _transcript
      ..clear()
      ..addAll(transcript);
  }

  /// 私有域绑定（**三态**，非二态）：null=未绑定走回退链 / ''=曾绑定但显式
  /// 回公共（不再回退）/ id=锁定。二态归并会丢「显式公共」（重启后回跳
  /// 自动绑定私有，`conversation_store.dart:61-63` 注释为 SSOT）。
  void bindPrivateServer(String? id) => _activePrivateServerId = id;

  /// 显式回公共（= `bindPrivateServer('')`，语义别名）。
  void unbindToPublic() => _activePrivateServerId = '';

  /// 持久化签名（§7.5 T6 / §8.3：**只立签名、不实现持久化**——真实落盘属
  /// `ConversationArchive`（Deferred），步 3 收口后另立 epic）。
  Map<String, Object?> toJson() =>
      throw UnimplementedError('只立签名；持久化属 ConversationArchive（Deferred）');

  factory ConversationSession.fromJson(Map<String, Object?> json) =>
      throw UnimplementedError('只立签名；持久化属 ConversationArchive（Deferred）');
}

// ---------------------------------------------------------------------------
// B2 · resolveBinding —— 会话绑定默认回退链（纯函数；步 3 接线替换
// chat_page._resolveBinding，本函数与彼逻辑逐行同构，等价性由测试钉住）
// ---------------------------------------------------------------------------

/// 回退链：已显式绑定直接用（'' → null = 显式公共）→ 全局钉选 isDefault →
/// 首个 private → null（纯公共）。
///
/// **调用方须先过滤 `enabled=false`**（`_send` 装配段语义；`_loadEndpoints`
/// 全量传入是既有行为，步 3 接线时统一收口）。
String? resolveBinding(List<ServerEndpoint> endpoints, {String? bound}) {
  if (bound != null) return bound.isEmpty ? null : bound;
  String? firstPrivate;
  for (final e in endpoints) {
    if (e.tier != ServerPrivacyTier.private) continue;
    if (e.isDefault) return e.id; // 全局钉选优先
    firstPrivate ??= e.id;
  }
  return firstPrivate;
}

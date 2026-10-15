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

import 'agent_loop.dart';
import 'cow_sync.dart' show CowMajorJumpDelegate;
import 'degradation_controller.dart';
import 'fenced_cloud_engine.dart' show PiiFenceDelegate;
import 'mcp_tool_face.dart';
import 'permission_gateway.dart' show GateDelegate;
import 'ref_hydrator.dart' show CrossSourceDelegate;
import 'tool_breaker.dart' show BlockDelegate;
import 'tool_router.dart';
import '../llm/cloud/cloud_llm.dart' show CloudChatMessage;
import '../mcp/connection_manager.dart';
import '../mcp/sampling.dart' show SamplingQuota;
import '../mcp/server_endpoints.dart';
import '../mcp/server_probe.dart' show McpClientFactory;
import '../sandbox/workspace_state_store.dart';

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

/// 连接回告（广播端口 `connectionReport` 的载荷，§7.1 #3）。
/// 判别靠类型构造（sealed），不设 kind 字段。
sealed class ConnectionReport {
  ConnectionReport.disconnect({required this.inFlightCancelled})
      : droppedCount = 0,
        uri = null;

  /// 重连成功但积压丢弃。
  ConnectionReport.backlog({required this.droppedCount})
      : inFlightCancelled = 0,
        uri = null;

  /// resources/updated：资源已陈旧。
  ConnectionReport.resourceUpdated(this.uri)
      : inFlightCancelled = 0,
        droppedCount = 0;

  /// 断连：在途已取消数（不重放语义由连接层保证）。
  final int inFlightCancelled;

  /// 积压丢弃数。
  final int droppedCount;
  final String? uri;
}

/// 装配八端口（§7.1 表）。`onToolCall` **不在内**——它是执行期事件流消费
/// （`await for (loop.run(...))`），属窗口渲染，塞进来会扩大搬迁边界。
///
/// 两类约束（§8.1-8）：
/// - **挂起**（`Future<T>`，Human-In-The-Loop，内核 `await`）：
///   gate / fence / block / consent / majorJump；
/// - **广播**（`void`，火即忘，内核不得 await）：onNote / onProgress / connectionReport。
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
    this.onNote,
    this.onProgress,
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

  // —— 广播（void）——

  /// 轨迹/告警注记（对应 chat `_add(TrackNote)`；danger=true 红字）。
  final void Function(String message, {bool danger})? onNote;

  /// 状态带工具进度（对应 `_setPill` + `loop.emitToolProgress` 桥接）。
  final void Function(String tool, num progress, num? total, String? message)?
      onProgress;

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
    required List<McpToolFace> faces,
    required List<McpConnection> connections,
  })  : _faces = List<McpToolFace>.unmodifiable(faces),
        _connections = List<McpConnection>.unmodifiable(connections);

  final AgentLoop loop;
  final ToolRouter router;

  /// 内部闭环（§8.1-3）：abort 遍历**全部** face 取消在途——不依赖「当前哪个
  /// face 在跑」的偶然性（现 `chat_page:959` 取 `faces[serverIds.first]`）。
  final List<McpToolFace> _faces;
  final List<McpConnection> _connections;

  /// RefStore 步 1 随 `assemble` 一并封入（§8.1-3：connections/refStore 不外泄）。
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
    for (final f in _faces) {
      try {
        f.client.close();
      } on Object catch (e) {
        developer.log('[DEGRADE] mcp-runtime: client.close failed: $e');
      }
    }
  }
}

// ---------------------------------------------------------------------------
// T5c · McpRuntime —— 装配入口（步 0 立签名，步 1 搬迁后实现）
// ---------------------------------------------------------------------------

/// MCP 侧 Run 级装配（§3.3 命名裁决：McpRuntime，不用 ServiceRuntime——云端
/// 引擎侧 Run 级装配已由 `hybrid_assembly.dart` 承载）。
class McpRuntime {
  const McpRuntime();

  /// 装配（§8.1-3）：`chat_page._send` 装配段（658-970）步 1 搬迁至此。
  ///
  /// - [context]：会话快照入参（T1）；
  /// - [delegates]：八端口（T3）；
  /// - [quota]：**实例独立入参**（T2 / §8.1-4，`20 次/60min`·按 serverKey 分桶，
  ///   非 token 数非 bool）——chat 传 Session 持有实例，gateway 侧 null = 内部 new；
  /// - [clientFactory]：**注入位**（T5c，范式 `server_probe.dart:49-52`），
  ///   默认 `McpClient.http`——步 1「全部连接已 close」断言经此注入 fake client。
  Future<McpAssembly> assemble({
    required SessionContext context,
    RuntimeDelegates delegates = const RuntimeDelegates(),
    SamplingQuota? quota,
    McpClientFactory? clientFactory,
  }) async =>
      throw UnimplementedError('步 1 搬迁装配段（chat_page._send 658-970）后实现');
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

  /// 三态：null=未绑定 / ''=显式公共 / id=锁定。
  String? get activePrivateServerId => _activePrivateServerId;

  /// 只读视图；写回唯一通道 = [replaceTranscript]。
  List<CloudChatMessage> get transcript => List.unmodifiable(_transcript);

  /// **全量替换**（非 append！）：对应现 `chat_page:1067` 的
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

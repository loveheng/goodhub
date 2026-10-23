/// 网关协议处理器（G1/G2，thirdconnect.md §7）：把 PC（MCP client）入站请求
/// 映射到 GoodHub 聚合工具面。
///
/// - **聚合单入口（G2）**：`tools/list` 全量聚合本地 Binder 插件 face + 远端
///   HTTP server face；工具名前缀 `<server_id>__<tool>`（ToolRouter 同款前缀
///   语义，PC 对命名空间完全透明）；
/// - **按前缀分发（G2）**：`tools/call` 剥前缀取裸名直达 `face.client`
///   （`callWithProgress` per-call 进度闭包——并发安全，进度帧由服务器层转
///   SSE 下行给 PC）；
/// - **目录变更广播（§9.2）**：包变更重扫后 [notifyToolsListChanged]，经
///   GET /mcp 的 SSE 流下行 `notifications/tools/list_changed`，PC 客户端
///   自动重拉 tools/list（跨端 Schema 热同步）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../coordinator/mcp_tool_face.dart';
import '../coordinator/pii_fence.dart' show redactSync;
import '../coordinator/ref_store.dart' show parseRefHandle;
import '../coordinator/tool_router.dart';
import '../mcp/server_capabilities.dart' show kMcpProtocolVersion;
import '../mcp/transport/host_transport.dart' show kHostServerId;
import 'gateway_backpressure.dart' show PerServerBackpressure;
import 'gateway_loop_guard.dart';
import 'gateway_system_tools.dart' as sys;
import 'gateway_security.dart';
import 'projection_pipeline.dart';

class GatewayHandler {
  GatewayHandler({
    required this.faces,
    this.security,
    this.privateServerIds = const {},
    this.activePrivateServerId,
    this.onListChanged,
    this.policy = const ProjectionPolicy.full(),
    this.blockedPlugins = const {},
    GatewayLoopGuard? loopGuard,
  }) : _loopGuard = loopGuard ?? GatewayLoopGuard();

  /// 已挂载 face 集（serverId → face；GatewayController 装配/重扫时**原地**刷新，
  /// 所有会话投影共享同一引用——改一地全连接可见）。
  final Map<String, McpToolFace> faces;

  /// 私有服务 id 集（MO6 投影边界）：由 GatewayController 按端点
  /// `ServerEndpoint.tier` 注入。命中集的 face 仅当等于**本连接**
  /// [activePrivateServerId] 时才进该连接的 PC 投影（MO2 私有不进共享面 +
  /// 阶段二每连接独立投影）。
  Set<String> privateServerIds;

  /// 本连接（会话）当前激活私有域（阶段二：每 `Mcp-Session-Id` 独立）。null/'' =
  /// 无激活私有（仅 public 投影）。PC 调用非本域私有服务由 [toolsCall] 防火墙拒绝。
  String? activePrivateServerId;

  /// 入站安全闭环（G3，null = 直通——仅限测试；生产由 controller 注入）。
  final GatewaySecurity? security;

  /// 目录变更通知回调（本连接投影切换 → 通知 PC 重拉自身 tools/list）。
  /// 由 GatewayController 注入为共享 `_listChanged` 的触发（所有连接同播）。
  final void Function()? onListChanged;

  /// **本连接绑定的投影策略**（host-tools-gateway-export PR2）：`initialize` 期
  /// 由服务器层解析 URL query 后经 [forSession] 派生注入；此后**可由本连接的
  /// `gateway__select_private(policy=single|private|full)` 切换**（用户裁决
  /// 2026-10-23；旧参数 `scope=` 为兼容别名，不进 schema）。
  ///
  /// **可变的边界**：只改**本连接**的投影视图，与 [activePrivateServerId] 同性质
  /// ——绝不触碰宿主私有槽位机、不影响其他连接，故 MO6「PC 无权改写宿主状态」
  /// 不受影响（被禁的 `use_server` 改的是宿主槽位，二者不同源）。
  ProjectionPolicy policy;

  /// **已发现但未挂载**的本地插件（serverId → 原因；仅 id 与原因，不含包名 /
  /// 签名 / Service 类名）。装配层（`GatewayController`）在信任闸门拦下插件时
  /// 记账于此，供 `gateway__list_servers` 的 `blocked` 段透出——让 PC 侧能区分
  /// 「宿主没装这个服务」与「装了但尚未信任」，避免把排障支去错方向。
  final Map<String, String> blockedPlugins;

  /// 入站环路防护（A2 止血：Trace-ID 在途集合 + hop_count 深度熔断）。
  /// **每连接独立**（阶段二裁决 per-session loop guard）——单连接的调用链异常
  /// 绝不应熔断另一正常连接。
  final GatewayLoopGuard _loopGuard;

  /// 入站背压（§9.6）：单 server 并发硬上限 4，超限排队（只包真实执行段，
  /// L2 确认等待不占并发槽）。**每连接独立**（阶段二裁决 per-session
  /// backpressure）——避免多客户端场景单连接饿死全局配额。
  final PerServerBackpressure _backpressure = PerServerBackpressure();

  /// 网关级系统工具（**声明与文案 owner = `gateway_system_tools.dart`**；
  /// #18 体量治理：本文件只留接线与连接态）。
  ///
  /// 命名空间 `gateway__` 明确标定其为网关系统工具，不污染业务 MCP 服务命名空间，
  /// 且在网关入站路由层做专用拦截（绝不转交任何 face / 宿主槽位机）。
  static const kGatewaySelectPrivate = sys.kGatewaySelectPrivate;

  /// 列出宿主**当前已挂载的全部 MCP 服务**（术语纠错：列全部而非只列「私有」，
  /// 详见新件注释）。
  static const kGatewayListServers = sys.kGatewayListServers;

  /// 网关级系统工具命名空间前缀（零泄漏判定与分派共用）。
  static const _kGatewayPrefix = sys.kGatewayToolPrefix;

  /// 对 PC 暴露的协议版本（单一事实源 = `mcp/server_capabilities.dart` 的
  /// [kMcpProtocolVersion]——此前本处为字面量复制，改协议版本会静默分叉）。
  static const _protocolVersion = kMcpProtocolVersion;

  /// 工具目录变更信号（broadcast；GatewayServer 订阅后向 SSE 订阅者下行）。
  final _listChanged = StreamController<void>.broadcast();
  Stream<void> get onToolsListChanged => _listChanged.stream;
  void notifyToolsListChanged() => _listChanged.add(null);

  /// initialize 握手结果（对外只声明 tools 能力——prompts/resources 聚合
  /// 留后续任务；listChanged=true 声明 §9.2 热同步语义）。
  Map<String, Object?> initialize() => {
        'protocolVersion': _protocolVersion,
        'capabilities': {
          'tools': {'listChanged': true},
        },
        'serverInfo': {'name': 'GoodHub Gateway', 'version': '0.1.0'},
      };

  /// 由模板 handler 派生「每连接」实例（阶段二 D-D 投影隔离支点）：
  /// 共享 [faces] / [privateServerIds] 引用，复制当前宿主默认激活私有，持有
  /// 独立 `_loopGuard` / `_backpressure` / `onListChanged`。`onListChanged` 统一
  /// 指向模板的共享 `_listChanged`，确保任一连接的投影切换广播到全部连接。
  GatewayHandler forSession({
    ProjectionPolicy? policy,
    String? activePrivateServerId,
  }) =>
      GatewayHandler(
        faces: faces,
        privateServerIds: privateServerIds,
        // 连接级私有投影绑定：URL 指定 `single&server=<私有服务>` 时由服务器层
        // 传入（**仅改本连接**，绝不触碰宿主槽位机——与 `gateway__select_private`
        // 同权限集合，MO6「PC 不得改写宿主状态」不受影响）。
        activePrivateServerId: activePrivateServerId ?? this.activePrivateServerId,
        policy: policy ?? this.policy,
        // 2026-10-17 P0-B：安全上下文**随连接派生**（此前是同一引用，导致
        // PC-A 的「本会话记住」给 PC-B 同工具免 L2 确认 = 跨会话提权）。
        security: security?.forSession(),
        onListChanged: () => _listChanged.add(null),
      );

  /// 连接回收时释放本连接的安全上下文（P0-B）：per-session 豁免集随连接销毁，
  /// 不留内存态。幂等，可在 stop / idle GC 等任意回收路径调用。
  void disposeSession() => security?.resetSessionGrants();

  /// 网关级系统工具 [kGatewayListServers]：列出宿主**当前已挂载的全部 MCP 服务**。
  ///
  /// 每条只给 `server_id` / `tier` / `source` / 只读工具数 / 是否当前目标——
  /// **不含凭据、端点地址、服务自报名（可能含用户自定义命名）或任何服务内容**。
  /// 服务 id 本就在既有 `kGatewaySelectPrivate` 拒绝话术中回显过，故不新增暴露面。
  ///
  /// **实时性**：每次调用现算，不依赖 `tools/list` 快照——宿主刚改完配置即可复查，
  /// 无需重连会话。
  GatewayToolResult _handleListServers() {
    final rows = [
      for (final entry in faces.entries)
        () {
          final id = entry.key;
          final isPrivate = privateServerIds.contains(id);
          final isTarget =
              policy.isSingle && policy.targetServerId == id;
          return <String, Object?>{
            'server_id': id,
            // 端点隐私级别：仅手填端点可私有；本地插件恒 public（系统托管常驻曝光）。
            'tier': isPrivate ? 'private' : 'public',
            // 来源分类（供 PC 判断可动性）：host = 宿主虚拟服务；endpoint-private =
            // 私有端点；public = 本地插件或 public 端点。
            'source': id == kHostServerId
                ? 'host'
                : (isPrivate ? 'endpoint-private' : 'public'),
            'shared_tools': entry.value.cachedSchemas.where((s) => s.isShared).length,
            'current': id == activePrivateServerId,
            'policy_target': isTarget,
          };
        }(),
    ]..sort((a, b) =>
        (a['server_id']! as String).compareTo(b['server_id']! as String));
    if (rows.isEmpty) {
      return GatewayToolResult(
        content: blockedPlugins.isEmpty
            ? '宿主当前未挂载任何 MCP 服务'
                '（可在宿主 ⚙ 设置 → 节点添加端点，或安装本地插件；'
                '装好后直接重调本工具即可，无需重连）'
            : jsonEncode(<String, Object?>{
                'servers': <Object?>[],
                'blocked': [
                  for (final e in blockedPlugins.entries)
                    {'server_id': e.key, 'reason': e.value},
                ],
                'blocked_hint': '这些 MCP 插件已安装但尚未被宿主信任，'
                    '按 reason 在宿主侧信任后重调本工具即可',
              }),
        isError: false,
      );
    }
    return GatewayToolResult(
      content: jsonEncode(<String, Object?>{
        'servers': rows,
        if (blockedPlugins.isNotEmpty)
          'blocked': [
            for (final e in blockedPlugins.entries)
              {'server_id': e.key, 'reason': e.value},
          ],
        'hint': '只想跟其中一个服务打交道 → '
            'gateway__select_private(server_id=<id>, policy=single)'
            '（目录只剩它的无前缀工具；回联邦面用 policy=full；'
            '叠加某个私有服务用 policy=private）',
        if (blockedPlugins.isNotEmpty)
          'blocked_hint': 'blocked 段列出的是已安装但尚未被宿主信任的 MCP 插件，'
              '按 reason 在宿主侧完成信任后重调本工具即可（无需重连）',
        'policy': switch (policy.strategy) {
          ProjectionStrategy.single => 'single(${policy.targetServerId})',
          ProjectionStrategy.private => 'private(${policy.targetServerId})',
          ProjectionStrategy.pruned => 'pruned(${policy.tags.join(",")})',
          ProjectionStrategy.full => 'full',
          // owner = 宿主内部档（无 URL 入口，网关侧不可达）——防御性分支：
          // 真走到这里说明有代码绕过 owner 档的入口约束，按内部档原样回报。
          ProjectionStrategy.owner => 'owner',
        },
      }),
      isError: false,
    );
  }

  /// 网关级系统工具 [kGatewaySelectPrivate] 处理：**仅改写本连接**的投影
  /// （[activePrivateServerId] 与 [policy]），绝不触碰宿主 `discovery_executor`
  /// 槽位机或任何 face（连接级投影切换）。
  ///
  /// **单轴化（2026-10-23 用户裁决 D1）**：参数 `policy` 为**主名**，`scope`
  /// 为**兼容别名**（同传时 `policy` 优先；schema 只暴露 `policy` → PC 侧
  /// 只记一套词表）。字面量四档 `single` / `private` / `full` / `pruned`——
  /// `pruned` **仅连接建立期可用**（`?policy=pruned&tag=…`；连接内无 tag
  /// 来源，故此处显式拒绝并给可自纠话术）。
  /// 完成后经 `onListChanged` 通知 PC 重拉自身 tools/list。
  GatewayToolResult _handleSelectPrivate(Map<String, Object?> arguments) {
    final raw = arguments['server_id'];
    if (raw is! String) {
      return const GatewayToolResult(
        content: 'gateway__select_private 缺少 server_id 参数'
            '（传服务 id；传 "all" 或空串清空为公共面/完整联邦面）',
        isError: true,
      );
    }
    // 兼容别名：`policy` 主名，`scope` 旧名（同传时 `policy` 优先）。
    final requested = switch (arguments['policy']) {
      final String s when s.trim().isNotEmpty => s.trim(),
      _ => switch (arguments['scope']) {
          final String s when s.trim().isNotEmpty => s.trim(),
          _ => 'private',
        },
    };
    if (requested != 'single' &&
        requested != 'private' &&
        requested != 'full' &&
        requested != 'pruned') {
      return const GatewayToolResult(
        content: 'policy 取值非法（合法字面量：single / private / full / pruned）',
        isError: true,
      );
    }
    if (requested == 'pruned') {
      return const GatewayToolResult(
        content: 'policy=pruned 仅在连接建立期可用（?policy=pruned&tag=<tag>）——'
            '连接内切换无 tag 来源；请改用 policy=single（单服务，收敛上下文）',
        isError: true,
      );
    }
    final target = raw.trim();
    final isClear = target.isEmpty || target == 'all' || target == 'public';

    // `single` 的目标允许**任意已挂载服务**（不限于私有）——single 是通用
    // 收敛语义；私有服务另需连接级绑定（防火墙据此放行）。
    if (!isClear) {
      if (!faces.containsKey(target)) {
        return GatewayToolResult(
          content: '服务 $target 当前未挂载（可能离线）——'
              '先用 gateway__list_servers 查看可用服务',
          isError: true,
        );
      }
      if (requested == 'private' && !privateServerIds.contains(target)) {
        return GatewayToolResult(
          content: 'server_id=$target 不是私有服务'
              '（policy=private 仅可在已配置的私有域中选择；'
              '要用非私有服务请传 policy=single）',
          isError: true,
        );
      }
    }

    if (requested == 'single') {
      if (isClear) {
        return const GatewayToolResult(
          content: 'policy=single 必须指定具体服务 id'
              '（server_id="all" 只在 policy=full 下有意义）',
          isError: true,
        );
      }
      policy = ProjectionPolicy.single(target);
      activePrivateServerId =
          privateServerIds.contains(target) ? target : activePrivateServerId;
    } else if (requested == 'full') {
      policy = const ProjectionPolicy.full();
      activePrivateServerId = null;
    } else {
      // policy=private：完整联邦面 + 该私有服务（私有叠加只对本连接生效）
      if (isClear) {
        return const GatewayToolResult(
          content: 'policy=private 必须指定具体私有服务 id'
              '（server_id="all" 只在 policy=full 下有意义）',
          isError: true,
        );
      }
      policy = ProjectionPolicy.private(target);
      activePrivateServerId = target;
    }
    onListChanged?.call();
    return GatewayToolResult(
      content: sys.describeGatewayProjection(
        policy,
        activePrivateServerId: activePrivateServerId,
      ),
      isError: false,
    );
  }

  /// tools/list 聚合（G2 + MO6 投影 + F1.9 海关过滤）：仅回 **public 全量 +
  /// 本连接激活 private**（其余私有服务不进本连接投影——阶段二每连接独立私有面），
  /// 且**只回 `visibility == shared` 的工具**（SDK 0.2.0 声明式标记；缺失即
  /// private = 不向外部 Agent 暴露——对外暴露面 default-deny），
  /// 并追加网关级系统工具 [kGatewaySelectPrivate]（连接投影切换）。
  ///
  /// **声明非 ACL**：过滤只在目录层收窄（PC 看不见即不可达），`tools/call` 不
  /// 因可见性额外拦截——调用方可信性由信任白名单 / L2 确认卡独立把关，可见性
  /// 不是安全边界。
  List<Map<String, Object?>> toolsList() {
    final result = project();
    _lastProjection = result.signature;
    return [for (final t in result.tools) t.toJson()];
  }

  /// 网关级系统工具声明（JSON owner = `gateway_system_tools.dart`）。抽出为
  /// getter 供投影管道消费（`single` 策略下管道按策略不纳入）。
  static List<Map<String, Object?>> get systemToolJson =>
      sys.buildGatewaySystemToolJson();

  /// **四级过滤管道唯一入口**（PR2）：visibility 海关 → 私有投影防火墙 →
  /// 策略过滤 → 命名格式化。`toolsList`、广播差分、入站边界判定三处共用
  /// 本投影结果（**同源**，杜绝「目录看得到、调用被拒」的不一致）。
  ProjectionResult project() {
    // 系统工具裁剪：`single` 只留 `gateway__select_private`（退出 single 的
    // **唯一出口**——全隐匿即死锁）；`gateway__list_servers` 在 single
    // 下无意义（已锁定单一目标），一并隐匿。
    final tools = policy.isSingle
        ? [
            for (final t in systemToolJson)
              if (t['name'] == kGatewaySelectPrivate) t,
          ]
        : systemToolJson;
    return ProjectionFilter.project(
      faces: faces,
      privateServerIds: privateServerIds,
      // `policy=private` 自带私有叠加目标（联邦面 + 该私有服务）；其余档用
      // 连接上的显式私有绑定（single 指向私有服务时的连接级绑定 / full 档为 null）。
      activePrivateServerId:
          policy.isPrivate ? policy.targetServerId : activePrivateServerId,
      policy: policy,
      systemTools: tools,
    );
  }

  /// 上次广播/列目录时的投影集签名（**null = 尚未建立基线**）。
  Set<String>? _lastProjection;

  /// 投影集基线（会话建立 / 每次 `toolsList` 后刷新）——广播差分的比较基准。
  void markProjectionBaseline() => _lastProjection = project().signature;

  /// 目录变更广播的投影差分判定（PR2）：重算当前投影集并与上次快照比对，
  /// **无变化即抑制**——同时覆盖「`single` 会话对无关服务上下线无感」与
  /// 「`full` 会话对私有域变更无感」两类噪音。
  bool projectionChangedSinceBaseline() {
    final now = project().signature;
    final prev = _lastProjection;
    _lastProjection = now;
    return prev == null || !_setEquals(prev, now);
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// tools/call 分发（G2）：剥前缀 → face.client 流式执行，进度经 [onProgress]
  /// 回调（服务器层转 SSE 帧）。协议错误/目标缺失转 isError 结果不抛穿。
  /// G3：已路由调用经 [security] 管线（L1/L2 裁决 → 执行 → PII 出站过滤 → 审计）。
  Future<GatewayToolResult> toolsCall({
    required String name,
    required Map<String, Object?> arguments,
    required void Function(Map<String, Object?> progressParams) onProgress,
    String? traceId,
    int hopCount = 0,
    String? sessionId,
  }) async {
    // 网关级系统工具（阶段二 D-D + 用户裁决 2026-10-23）：连接投影切换 / 私有服务
    // 列举。先于任何路由/防火墙拦截，仅改写「本连接」投影，绝不触碰宿主槽位机
    // 或任何 face。
    if (name.startsWith(_kGatewayPrefix)) {
      // single 下的控制面收窄：**只放行出口工具** `select_private`（否则 PC
      // 切进 single 后出不来 = 死锁）；其余网关工具显式拒绝。
      if (policy.isSingle && name != kGatewaySelectPrivate) {
        return const GatewayToolResult(
          content: 'gateway__* 是网关连接级系统工具，single 策略下只保留 '
              'gateway__select_private 作为退出通道；'
              '回完整联邦面请调 gateway__select_private(server_id="all", '
              'policy=full)，无需重连',
          isError: true,
        );
      }
      if (name == kGatewayListServers) return _handleListServers();
      if (name == kGatewaySelectPrivate) return _handleSelectPrivate(arguments);
      return GatewayToolResult(
        content: '未知网关系统工具 $name（可用：$kGatewayListServers / '
            '$kGatewaySelectPrivate）',
        isError: true,
      );
    }
    // 入站工具名判定（PR2）：系统工具拒绝 → single 前缀补齐 / 投影集边界 →
    // 既有 parsePrefixedToolName 之后的全部分发逻辑。
    final inbound = resolveInboundToolName(
      name: name,
      policy: policy,
      isProjected: _isProjected,
    );
    if (inbound is InboundProtocolError) {
      return GatewayToolResult(
          content: inbound.message, isError: true, errorCode: inbound.code);
    }
    if (inbound is InboundRejected) {
      return GatewayToolResult(content: inbound.reason, isError: true);
    }
    final effectiveName = (inbound as InboundAllowed).resolvedName;
    final parsed = parsePrefixedToolName(effectiveName);
    if (parsed == null) {
      // 纵深防御：投影管道已判过形态，此处不可达（保留以免上游改判定时静默失守）。
      return GatewayToolResult(
        content: '工具名 $effectiveName 缺少服务前缀（应形如 <server_id>__<tool>）',
        isError: true,
      );
    }
    // 环路防护（A2 止血）：**先于路由**——① 协议级错误优先于业务路由；
    // ② 级联风暴下被阻断的流量连注册表都不查（不为无效请求付查询成本）。
    final trace = traceId ?? _loopGuard.newTraceId();
    final blocked = _loopGuard.checkInbound(traceId: trace, hopCount: hopCount);
    if (blocked != null) {
      debugPrint('[gateway] loop-blocked: $blocked');
      return GatewayToolResult(
        content: '环路防护拒绝：$blocked',
        isError: true,
        errorCode: kGatewayLoopBlockedCode,
      );
    }

    // 防火墙（MO6 阶段一：PC 只读镜像）——私有服务仅放行「当前激活私有域」，
    // 其余私有调用一律拒绝：不暴露、不可达，且 PC 无权经网关发起 use_server
    // 动态换绑（防改写宿主 activePrivateServerId 造成跨会话状态踩踏）。
    if (privateServerIds.contains(parsed.serverId) &&
        parsed.serverId != activePrivateServerId) {
      return GatewayToolResult(
        content: '私有服务 ${parsed.serverId} 不在当前激活私有域——网关对 PC '
            '为只读镜像，仅暴露宿主当前激活私有域；禁止经网关发起 use_server '
            '动态换绑。',
        isError: true,
      );
    }

    // MO7 跨源 $ref 防火墙（仅网关入站 / 跨源边界，坚决不侵入本地同进程）：
    // 入站 tools/call 携带指向「非目标服务」的 $ref 句柄 = 跨服务引用（PC / 外部
    // MCP 持某服务私有句柄去调另一服务）——须持有效网关会话（Session Context /
    // Mcp-Session-Id）否则拒绝。本地同进程调用（AgentLoop / ToolRouter）不走
    // toolsCall，故守卫不污染 coordinator/；LAN 直连 goodhub 无网关投影面，靠
    // 「私有不进共享面」兜底。守卫只做会话归属校验——网关是代理、按字面转发句柄，
    // 不做注水（注水属宿主运行时路径，单私有槽已结构性安全），故不引入 RefStore
    // 解析依赖（防过度设计）。
    final crossRefs = _crossSourceRefHandles(arguments, parsed.serverId);
    if (crossRefs.isNotEmpty && (sessionId == null || sessionId.isEmpty)) {
      return GatewayToolResult(
        content: '跨服务 \$ref 句柄 ${crossRefs.join(', ')} 须持有效网关会话'
            '（Session Context）方可越服务引用；当前入站请求未携带会话，拒绝。',
        isError: true,
      );
    }

    final face = faces[parsed.serverId];
    if (face == null) {
      return GatewayToolResult(
        content: '服务 ${parsed.serverId} 未挂载（可能离线）',
        isError: true,
      );
    }

    Future<GatewayToolResult> run() async {
      try {
        // §9.6 背压：单 server 并发硬上限 4，超限排队（真实执行段才占槽，
        // L2 确认等待不占）。
        final result = await _backpressure.run(parsed.serverId, () {
          return face.client.callWithProgress(
            'tools/call',
            params: {
              'name': parsed.toolName,
              'arguments': arguments,
              // 出站透传（SA-Q5 兜底线）：`_meta` 与 name/arguments **平级**，
              // 严禁塞进 arguments（强校验插件会报 unknown parameter）。下游
              // 若为另一台 goodhub 网关则据此递增深度；标准第三方 server 忽略
              // `_meta` 亦无副作用（它不具备反向回调本网关的能力，本就不成环）。
              // 恒注入（含入站无 Trace-ID 的自派场景）——否则回环请求会丢失
              // 深度信息，兜底线在第一跳即失效。
              '_meta': <String, Object?>{'traceId': trace, 'hopCount': hopCount + 1},
            },
            // progress 帧 message 同步遮蔽（redactSync 纯函数直用：瞬态帧不并
            // 会话映射，占位符编号不跨帧稳定；终局结果由 security 层会话级遮蔽
            // 兜一致性）。遮蔽失败帧原样透传（进度非数据面，不因瞬态文本断流）。
            onProgress: (raw) {
              if (raw is! Map<String, Object?>) return;
              var p = raw;
              final msg = p['message'];
              if (msg is String && msg.isNotEmpty) {
                try {
                  p = {
                    ...p,
                    'message': redactSync(msg, const <String, String>{}).text,
                  };
                } on Object catch (_) {}
              }
              onProgress(p);
            },
          );
        });
        return _parseToolResult(result);
      } on Object catch (e) {
        return GatewayToolResult(content: '工具执行失败: $e', isError: true);
      }
    }

    // 在途登记必须在 try 之前，释放必须在 finally：覆盖成功 / 失败 / 超时 /
    // 客户端强断四条路径（只在正常返回位释放会让长连接中断的 traceId 泄漏，
    // 退化成 TTL 到期才恢复）。
    _loopGuard.acquire(trace);
    try {
      final sec = security;
      if (sec == null) return await run();
      return await sec.guard(
        serverId: parsed.serverId,
        tool: name,
        annotations: _annotationsFor(parsed, face),
        argumentsJson: jsonEncode(arguments),
        run: run,
      );
    } finally {
      _loopGuard.release(trace);
    }
  }

  /// 投影集边界判定（`single` 投影即调用边界）：当前投影集内是否存在该工具。
  /// **实时重算**（不读目录快照）——face 重扫后即刻生效，杜绝陈旧快照误拒。
  bool _isProjected(String serverId, String bareName) =>
      project().signature.contains('$serverId/$bareName');

  /// 前缀化工具的 annotations（L1/L2 裁决的 readOnlyHint 源；未命中 → null）。
  Map<String, Object?>? _annotationsFor(
    ({String serverId, String toolName}) parsed,
    McpToolFace face,
  ) {
    for (final s in face.cachedSchemas) {
      if (s.name == parsed.toolName) return s.annotations;
    }
    return null;
  }

  /// MO7 跨源 $ref 扫描：递归收集入参中「引用 serverId ≠ 目标 serverId」的
  /// 句柄。整值匹配口径（与 `ref_hydrator` 一致）：仅当字符串 trim 后整值恰为
  /// `$ref:<server>:<id>` 才计为句柄，描述文本内嵌子串不计（防误杀正常参数）。
  static List<String> _crossSourceRefHandles(
    Object? value,
    String targetServerId,
  ) {
    final out = <String>[];
    void walk(Object? v) {
      if (v is String) {
        final t = v.trim();
        final p = parseRefHandle(t);
        if (p != null && p.serverId != targetServerId) out.add(t);
      } else if (v is Map<Object?, Object?>) {
        for (final e in v.values) {
          walk(e);
        }
      } else if (v is List<Object?>) {
        for (final e in v) {
          walk(e);
        }
      }
    }

    walk(value);
    return out;
  }

  /// MCP tool result（{content:[{type:'text',text}...], isError}）→ 扁平结果
  /// （与 McpToolFace._parseToolResult 同口径）。
  GatewayToolResult _parseToolResult(Object? result) {
    if (result is! Map) {
      return const GatewayToolResult(
        content: '工具返回形状异常（非 object）',
        isError: true,
      );
    }
    final texts = <String>[];
    final content = result['content'];
    if (content is List) {
      for (final c in content) {
        if (c is Map && c['type'] == 'text' && c['text'] is String) {
          texts.add(c['text'] as String);
        }
      }
    }
    return GatewayToolResult(
      content: texts.isEmpty ? '(工具无文本内容返回)' : texts.join('\n'),
      isError: result['isError'] == true,
    );
  }
}

/// tools/call 网关侧扁平结果（MCP result 形状由服务器层重组）。
class GatewayToolResult {
  const GatewayToolResult({
    required this.content,
    required this.isError,
    this.errorCode,
  });
  final String content;
  final bool isError;

  /// 非 null = 协议级错误（server 层按此码回 JSON-RPC error 帧而非 result）。
  /// 目前仅环路阻断用（[kGatewayLoopBlockedCode]）——业务失败一律走 isError。
  final int? errorCode;
}

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
import 'gateway_backpressure.dart' show PerServerBackpressure;
import 'gateway_loop_guard.dart';
import 'gateway_security.dart';

class GatewayHandler {
  GatewayHandler({
    required this.faces,
    this.security,
    this.privateServerIds = const {},
    this.activePrivateServerId,
    this.onListChanged,
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

  /// 入站环路防护（A2 止血：Trace-ID 在途集合 + hop_count 深度熔断）。
  /// **每连接独立**（阶段二裁决 per-session loop guard）——单连接的调用链异常
  /// 绝不应熔断另一正常连接。
  final GatewayLoopGuard _loopGuard;

  /// 入站背压（§9.6）：单 server 并发硬上限 4，超限排队（只包真实执行段，
  /// L2 确认等待不占并发槽）。**每连接独立**（阶段二裁决 per-session
  /// backpressure）——避免多客户端场景单连接饿死全局配额。
  final PerServerBackpressure _backpressure = PerServerBackpressure();

  /// 网关级系统工具：连接投影切换（Connection Projection Switch）。
  /// 命名空间 `gateway__` 明确标定其为网关系统工具，不污染业务 MCP 服务命名空间，
  /// 且在网关入站路由层做专用拦截（绝不转交任何 face / 宿主槽位机）。
  static const kGatewaySelectPrivate = 'gateway__select_private';

  /// 对 PC 暴露的协议版本（与宿主客户端 kMcpProtocolVersion 同源，§1）。
  static const _protocolVersion = '2025-06-18';

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
  GatewayHandler forSession() => GatewayHandler(
        faces: faces,
        privateServerIds: privateServerIds,
        activePrivateServerId: activePrivateServerId,
        // 2026-10-17 P0-B：安全上下文**随连接派生**（此前是同一引用，导致
        // PC-A 的「本会话记住」给 PC-B 同工具免 L2 确认 = 跨会话提权）。
        security: security?.forSession(),
        onListChanged: () => _listChanged.add(null),
      );

  /// 连接回收时释放本连接的安全上下文（P0-B）：per-session 豁免集随连接销毁，
  /// 不留内存态。幂等，可在 stop / idle GC 等任意回收路径调用。
  void disposeSession() => security?.resetSessionGrants();

  /// 网关级系统工具 [kGatewaySelectPrivate] 处理：**仅改写本连接** [activePrivateServerId]，
  /// 绝不触碰宿主 `discovery_executor` 槽位机或任何 face（连接级投影切换）。
  /// 完成后经 `onListChanged` 通知 PC 重拉自身 tools/list。
  GatewayToolResult _handleSelectPrivate(Map<String, Object?> arguments) {
    final raw = arguments['server_id'];
    if (raw is! String) {
      return GatewayToolResult(
        content: 'gateway__select_private 缺少 server_id 参数'
            '（传私有服务 id；传 "all" 或空串清空为公共面）',
        isError: true,
      );
    }
    final target = raw.trim();
    if (target.isEmpty || target == 'all' || target == 'public') {
      activePrivateServerId = null;
    } else if (!privateServerIds.contains(target)) {
      return GatewayToolResult(
        content: 'server_id=$target 不是私有服务（仅可在已配置的私有域中选择）',
        isError: true,
      );
    } else if (!faces.containsKey(target)) {
      return GatewayToolResult(
        content: '私有服务 $target 当前未挂载（可能离线）',
        isError: true,
      );
    } else {
      activePrivateServerId = target;
    }
    onListChanged?.call();
    return GatewayToolResult(
      content: activePrivateServerId == null
          ? '已切换本连接私有投影至公共面（无激活私有域）'
          : '已切换本连接私有投影至私有域 $activePrivateServerId',
      isError: false,
    );
  }

  /// tools/list 聚合（G2 + MO6 投影）：仅回 **public 全量 + 本连接激活
  /// private**（其余私有服务不进本连接投影——阶段二每连接独立私有面），
  /// 并追加网关级系统工具 [kGatewaySelectPrivate]（连接投影切换）。
  List<Map<String, Object?>> toolsList() => [
        for (final entry in faces.entries)
          if (!privateServerIds.contains(entry.key) ||
              entry.key == activePrivateServerId)
            for (final s in entry.value.cachedSchemas)
              {
                'name': ToolRouter.prefixed(entry.key, s.name),
                'description': s.description,
                'inputSchema': s.parametersSchema,
                if (s.annotations != null) 'annotations': s.annotations,
              },
        // 网关级系统工具：连接私有投影切换（阶段二 D-D，命名空间 gateway__）。
        {
          'name': kGatewaySelectPrivate,
          'description':
              '网关级连接投影切换（Connection Projection Switch）：将本 MCP 连接的'
              '私有域激活面切换至指定私有服务，不影响宿主或其他连接的私有选择。'
              'server_id 传私有服务 id；传 "all" 或空串清空为公共面。',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'server_id': {
                'type': 'string',
                'description': '目标私有服务 id；"all" 或空串 = 清空为公共面',
              },
            },
            'required': ['server_id'],
          },
        },
      ];

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
    // 网关级系统工具（阶段二 D-D）：连接投影切换。先于任何路由/防火墙拦截，
    // 仅改写「本连接」activePrivateServerId，绝不触碰宿主槽位机或任何 face。
    if (name == kGatewaySelectPrivate) {
      return _handleSelectPrivate(arguments);
    }
    final parsed = parsePrefixedToolName(name);
    if (parsed == null) {
      return GatewayToolResult(
        content: '工具名 $name 缺少服务前缀（应形如 <server_id>__<tool>）',
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

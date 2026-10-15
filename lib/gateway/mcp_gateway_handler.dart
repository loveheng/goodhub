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
import '../coordinator/tool_router.dart';
import 'gateway_backpressure.dart' show PerServerBackpressure;
import 'gateway_loop_guard.dart';
import 'gateway_security.dart';

class GatewayHandler {
  GatewayHandler({required this.faces, this.security, GatewayLoopGuard? loopGuard})
      : _loopGuard = loopGuard ?? GatewayLoopGuard();

  /// 已挂载 face 集（serverId → face；GatewayController 装配/重扫时原地刷新）。
  final Map<String, McpToolFace> faces;

  /// 入站安全闭环（G3，null = 直通——仅限测试；生产由 controller 注入）。
  final GatewaySecurity? security;

  /// 入站环路防护（A2 止血：Trace-ID 在途集合 + hop_count 深度熔断）。
  final GatewayLoopGuard _loopGuard;

  /// 入站背压（§9.6）：单 server 并发硬上限 4，超限排队（只包真实执行段，
  /// L2 确认等待不占并发槽）。
  final PerServerBackpressure _backpressure = PerServerBackpressure();

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

  /// tools/list 聚合（G2）：全部已挂载 face 的缓存 Schema 前缀化（PC 单入口）。
  List<Map<String, Object?>> toolsList() => [
        for (final entry in faces.entries)
          for (final s in entry.value.cachedSchemas)
            {
              'name': ToolRouter.prefixed(entry.key, s.name),
              'description': s.description,
              'inputSchema': s.parametersSchema,
              if (s.annotations != null) 'annotations': s.annotations,
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
  }) async {
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

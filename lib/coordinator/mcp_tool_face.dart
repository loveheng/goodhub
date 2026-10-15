/// MCP 工具面：tools/list Schema 拉取 + tools/call 执行环实现（M2-T2）。
///
/// 单 Server 最小工具面（goodshare）；ToolRouter 前缀隔离与 JIT 多 Server
/// 摘要留 M2.5（单 Server 阶段直接暴露服务端裸名，与 GoodshareTaskApi 同口径）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/errors/mcp_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../mcp/mcp_client.dart';
import '../sandbox/memory_store.dart';
import 'agent_loop.dart';

/// 工具执行进度通告（M2.5-T7）：progress/total 为 server 声明的绝对值
/// （起始帧 0/1）；message 可空。
typedef ToolProgressCallback = void Function(
  String toolName,
  num progress,
  num? total,
  String? message,
);

class McpToolFace implements ToolExecutor {
  McpToolFace({
    required this.client,
    this.serverId = 'goodshare',
    this.onProgress,
    this.opsLog,
  });

  final McpClient client;

  /// 来源/目标 Server 标识（M2.5-T4：$ref 句柄的跨源判定锚点——单 Server
  /// 阶段恒 'goodshare'，多 Server ToolRouter 接线时随连接装配）。
  final String serverId;

  /// progress 通告回调（T7）；null = 不因进度注入 token（sampling 声明流式
  /// 语义见 execute——完整卡状态机（Running(progress) 态/疑似卡死阈值）在
  /// M3-T2 经 AgentLoop 事件流呈现，本回调是最小呈现 + 环桥接通道。
  final ToolProgressCallback? onProgress;

  /// ops.log 审计汇（M4-T2，N4 全链路）：非空时每次 tools/call 执行（含入参
  /// 解析失败与协议异常）落一条审计（server=本 face.serverId；本地拦截工具
  /// 由各自执行器自审计 server='local'）。审计失败 DEGRADE 留痕不阻断工具。
  final MemoryStore? opsLog;

  /// 审计错误文本截断上限（ops.log 防膨胀；原文在调用方上下文里不丢）。
  static const _auditClip = 200;

  /// 在途执行计数（T4-3 D18）：[execute] 进入即 +1、结束 -1——含非流式 POST 在途，
  /// 是断连时「在途 N 个已取消」的 N 来源（cancelActiveRequest 取消其中可取消的流式项）。
  int _activeCalls = 0;
  int get inFlightCount => _activeCalls;

  /// 在途流式请求 id 集合（M3-T2）：[cancelActiveRequest] 的取消目标。
  final Set<int> _streamingIds = {};

  /// tools/list → 引擎工具声明。description/inputSchema 可缺省（防御解析），
  /// name 缺失 = 契约违规立即抛。结果缓存于 [cachedSchemas]（T6 ToolRouter
  /// 前缀改写 / JIT 静态摘要消费——能力目录随 tools/list 变更全量刷新，§8）。
  Future<List<CloudToolSchema>> listTools() async {
    final result = await client.call('tools/list');
    if (result is! Map) {
      throw const McpProtocolException('tools/list result is not an object');
    }
    final tools = result['tools'];
    if (tools is! List) {
      throw const McpProtocolException('tools/list missing tools array');
    }
    final out = <CloudToolSchema>[];
    for (final t in tools) {
      if (t is! Map) {
        throw const McpProtocolException('tool entry is not an object');
      }
      final name = t['name'];
      if (name is! String || name.isEmpty) {
        throw const McpProtocolException('tool entry missing name');
      }
      out.add(CloudToolSchema(
        name: name,
        description:
            t['description'] is String ? t['description'] as String : '',
        parametersSchema: t['inputSchema'] is Map
            ? (t['inputSchema'] as Map).cast<String, Object?>()
            : const {},
        annotations: t['annotations'] is Map
            ? (t['annotations'] as Map).cast<String, Object?>()
            : null,
      ));
    }
    _lastSchemas = List.of(out);
    return out;
  }

  List<CloudToolSchema> _lastSchemas = const [];

  /// 最近一次 [listTools] 结果（裸名；同步只读视图）。
  List<CloudToolSchema> get cachedSchemas => List.unmodifiable(_lastSchemas);

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    final sw = Stopwatch()..start();
    final result = await _executeInner(call);
    sw.stop();
    final log = opsLog;
    if (log != null) {
      try {
        await log.audit(
          server: serverId,
          tool: call.name,
          ok: !result.isError,
          durationMs: sw.elapsedMilliseconds,
          error: result.isError ? _clip(result.content) : null,
        );
      } catch (e) {
        debugPrint('[DEGRADE] mcp-tool-face: ops audit failed: $e');
      }
    }
    return result;
  }

  String _clip(String text) =>
      text.length <= _auditClip ? text : '${text.substring(0, _auditClip)}…';

  Future<ToolExecutionResult> _executeInner(AssembledToolCall call) async {
    _activeCalls++;
    int? streamId;
    Object? args;
    try {
      args = call.argumentsJson.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(call.argumentsJson);
    } on FormatException catch (e) {
      // 入参 JSON 损坏回填 isError 让模型自纠（不抛——抛错由执行环统一兜）
      _activeCalls--;
      return ToolExecutionResult(
        content: '工具入参 JSON 损坏: ${e.message}（请修正 JSON 后重试）',
        isError: true,
      );
    }
    if (args is! Map) {
      _activeCalls--;
      return const ToolExecutionResult(
        content: '工具入参必须是 JSON object',
        isError: true,
      );
    }
    try {
      final params = {'name': call.name, 'arguments': args};
      // M3（ai-app-split.md §3.11）：server 声明 sampling 时强制走流式——
      // 反向请求帧需要帧间夹带通道；onProgress 维持既有 opt-in。两者皆无 =
      // 普通单 JSON（Tier 2 零破坏）。negotiate 幂等缓存，握手失败回退普通
      // （连接级失败由调用统一兜）。
      var useStream = onProgress != null;
      if (!useStream) {
        try {
          useStream = (await client.negotiate()).hasSampling;
        } on McpException catch (_) {
          useStream = false;
        }
      }
      final result = useStream
          ? await client.callWithProgress(
              'tools/call',
              params: params,
              onProgress: (p) {
                final cb = onProgress;
                if (cb == null) return; // sampling 流式但无进度消费：帧只作通道
                if (p is Map<String, Object?> && p['progress'] is num) {
                  final total = p['total'];
                  final message = p['message'];
                  cb(
                    call.name,
                    p['progress']! as num,
                    total is num ? total : null,
                    message is String ? message : null,
                  );
                }
              },
              onRequestId: (id) {
                streamId = id;
                _streamingIds.add(id);
              },
            )
          : await client.call('tools/call', params: params);
      return _parseToolResult(result);
    } on McpException catch (e) {
      return ToolExecutionResult(content: '工具执行失败: ${e.message}', isError: true);
    } finally {
      if (streamId != null) _streamingIds.remove(streamId);
      _activeCalls--;
    }
  }

  /// Abort 级联 ③（architecture §10）：对在途流式 tools/call 下发 MCP 标准
  /// `notifications/cancelled` 通知（不只断 SSE）；无在途请求为 no-op。
  /// 取消目标 = 全部在途流式请求 id（T4-3 支持多并发在途取消）。
  /// 下发失败 [DEGRADE] 留痕禁静默（server 侧按 90s 超时兜底，不悬挂）。
  void cancelActiveRequest({String? reason}) {
    if (_streamingIds.isEmpty) return;
    for (final id in List.of(_streamingIds)) {
      unawaited(client
          .notify('notifications/cancelled', params: {
            'requestId': id,
            'reason': ?reason,
          })
          .then((_) {}, onError: (Object e) {
            debugPrint('[DEGRADE] mcp-tool-face: cancel notify failed: $e');
          }));
    }
  }

  /// MCP tool result（{content:[{type:'text',text}...], isError}）→ 扁平结果。
  ToolExecutionResult _parseToolResult(Object? result) {
    if (result is! Map) {
      return const ToolExecutionResult(
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
    return ToolExecutionResult(
      content: texts.isEmpty ? '(工具无文本内容返回)' : texts.join('\n'),
      isError: result['isError'] == true,
    );
  }
}

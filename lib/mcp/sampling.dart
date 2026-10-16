/// sampling 反向推理消费面（M3，goodshare 仓 ai-app-split.md §3.11 + 本仓
/// architecture.md §12/§15）：D3 拍板配额语义 + createMessage → 引擎单发映射。
///
/// 临时会话语义（architecture §15）：推理只用请求自带 messages + systemPrompt，
/// 无记忆沙盒注入、无 UI 轨迹；N7 出站围栏挂云引擎装饰器单咽喉——sampling 与
/// 常规 send 走同一引擎实例，遮蔽语义自然覆盖，无需旁挂。
///
/// 引擎解耦（arch-hardening ③）：本域不 import llm——引擎经 [SamplingEngine]
/// 最小端口注入，消息货币为 core [ChatMessageData]；云引擎适配见
/// `llm/cloud/sampling_engine.dart`。
library;

import 'dart:async';

import '../core/chat_message_data.dart';
import '../core/errors/mcp_error.dart';

/// D3 拍板配额：per-server 滑动窗口次数制——默认 20 次 / 60min；内存态不落盘
/// （重启清零，定位防滥用非计费）。超限抛 -32000（data 带 retry hint）。
class SamplingQuota {
  SamplingQuota({this.maxPerWindow = 20, this.window = const Duration(minutes: 60)});

  final int maxPerWindow;
  final Duration window;

  final Map<String, List<DateTime>> _hits = {};

  /// 扣减一次配额：允许返回 null；拒绝返回建议重试等待时长。
  Duration? tryConsume(String serverKey, DateTime now) {
    final hits = (_hits[serverKey] ??= <DateTime>[])
      ..removeWhere((t) => now.difference(t) > window);
    if (hits.length >= maxPerWindow) {
      final retry = window - now.difference(hits.first);
      return retry.isNegative ? Duration.zero : retry;
    }
    hits.add(now);
    return null;
  }

  /// 命中记录快照（epoch 毫秒；超窗条目就地清出，防快照无限增长）——
  /// ConversationArchive 落盘消费（archive-memory-claim 步 1，防杀进程刷新额度）。
  Map<String, List<int>> snapshotHits(DateTime now) => {
        for (final e in _hits.entries)
          e.key: [
            for (final t in e.value)
              if (now.difference(t) <= window) t.millisecondsSinceEpoch,
          ],
      };

  /// 恢复落盘的命中记录（进程重启语义；超窗条目由 tryConsume 惰性清除）。
  void restoreHits(Map<String, List<int>> hits) {
    _hits
      ..clear()
      ..addAll({
        for (final e in hits.entries)
          e.key: [
            for (final ms in e.value)
              DateTime.fromMillisecondsSinceEpoch(ms),
          ],
      });
  }
}

/// 单次输出硬顶（D3：宿主 maxTokens clamp；云端预算默认口径）。
const kSamplingMaxTokensCap = 1024;

/// sampling 反向推理引擎最小端口（arch-hardening ③）：单发文本推理 + 引擎名。
/// 生产实现 = 云引擎适配（`llm/cloud/sampling_engine.dart`）。
abstract interface class SamplingEngine {
  String get name;

  /// 单发推理：流式产出正文增量（临时会话语义由实现保证——无历史、无记忆注入）。
  Stream<String> sendText({
    required List<ChatMessageData> messages,
    required int maxTokens,
  });
}

/// McpClient.onServerRequest 处理器工厂：sampling/createMessage → 引擎单发
/// 推理 → MCP createMessage result 形状。配额超限抛 McpRpcException(-32000，
/// data 带 retry hint)；参数违规 -32602；未知反向请求 -32601。推理异常原样
/// 上抛——由 client 回程层统一转 -32603 error 帧。
Future<Map<String, Object?>?> Function(String method, Object? params)
    samplingRequestHandler({
  required SamplingEngine engine,
  required SamplingQuota quota,
  required String serverKey,
}) {
  return (method, params) async {
    if (method != 'sampling/createMessage') {
      throw McpRpcException(-32601, '未知反向请求: $method');
    }
    final denial = quota.tryConsume(serverKey, DateTime.now());
    if (denial != null) {
      throw McpRpcException(
        -32000,
        'sampling 配额超限（滑动窗口 ${quota.maxPerWindow} 次/'
        '${quota.window.inMinutes}min）',
        data: {
          'hint': 'retry after ${denial.inSeconds}s',
          'retry_after_seconds': denial.inSeconds,
        },
      );
    }
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    final rawMax = p['maxTokens'];
    final maxTokens = rawMax is num && rawMax.toInt() > 0
        ? (rawMax.toInt() > kSamplingMaxTokensCap ? kSamplingMaxTokensCap : rawMax.toInt())
        : kSamplingMaxTokensCap;
    final messages = <ChatMessageData>[];
    final systemPrompt = p['systemPrompt'];
    if (systemPrompt is String && systemPrompt.isNotEmpty) {
      messages.add(SystemChatMessage(systemPrompt));
    }
    final rawMessages = p['messages'];
    if (rawMessages is! List || rawMessages.isEmpty) {
      throw const McpRpcException(-32602, 'sampling/createMessage 缺少 messages');
    }
    for (final m in rawMessages) {
      if (m is! Map) {
        throw const McpRpcException(-32602, 'sampling messages 含非对象条目');
      }
      final text = m['content'] is Map ? (m['content'] as Map)['text'] : null;
      if (text is! String) {
        throw const McpRpcException(-32602, 'sampling message 缺少 text 内容');
      }
      messages.add(
          m['role'] == 'assistant' ? AssistantChatMessage(content: text) : UserChatMessage(text));
    }
    // 单发推理：流式聚合正文（临时会话——无历史、无记忆注入，§15）。
    final buf = StringBuffer();
    await for (final chunk
        in engine.sendText(messages: messages, maxTokens: maxTokens)) {
      buf.write(chunk);
    }
    return {
      'role': 'assistant',
      'model': engine.name,
      'content': {'type': 'text', 'text': buf.toString()},
    };
  };
}

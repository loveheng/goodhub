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
///
/// pool 分池（2026-10-17 instant-sampling 一期，goodshare 仓 ai-app-split.md
/// §3.11 回写）：server 经 sampling params 平级字段 `pool`（Tier 1 私有约定）
/// 声明档位；配额 key 派生为 `serverKey`（默认池）/ `serverKey:pool`（分池）。
/// **pool 是 server 传入的不可信值**——只有 [caps] 登记的档位名才分池，
/// 未登记 pool 归默认池与 serverKey 共享额度（防伪造 pool 名每名一池绕过
/// 限额）。caps 只承载记账档位、无业务语义；档位名是协议标识符（同字段名）。
class SamplingQuota {
  SamplingQuota({
    this.maxPerWindow = 20,
    this.window = const Duration(minutes: 60),
    Map<String, int> caps = const {'instant': 60},
  }) : caps = Map.unmodifiable(caps);

  /// 默认池上限（未登记 pool / 无 pool 的请求共用）。
  final int maxPerWindow;
  final Duration window;

  /// 分池档位覆盖表：pool 名 → 窗口次数上限。仅表内档位参与分池（白名单）。
  final Map<String, int> caps;

  final Map<String, List<DateTime>> _hits = {};

  /// 扣减一次配额：允许返回 null；拒绝返回建议重试等待时长。
  ///
  /// [pool] = server 声明的档位（params 平级字段）；未登记/空 = 默认池。
  /// 白名单判定在本方法内单点完成——调用方（handler）只透传 String，
  /// 伪造 pool 名在此归一，无第二判定处可漂移。
  Duration? tryConsume(String serverKey, DateTime now, {String? pool}) {
    final pooled = pool != null && pool.isNotEmpty && caps.containsKey(pool);
    final key = pooled ? '$serverKey:$pool' : serverKey;
    final cap = pooled ? caps[pool]! : maxPerWindow;
    final hits = (_hits[key] ??= <DateTime>[])
      ..removeWhere((t) => now.difference(t) > window);
    if (hits.length >= cap) {
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
///
/// `pool` 扩展字段（Tier 1 私有，params 平级 String，缺省/非 String = 默认
/// 池）：只作配额记账档位透传，本模块不识其业务语义——档位白名单与上限在
/// [SamplingQuota.caps] 单点。
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
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    final rawPool = p['pool'];
    final denial = quota.tryConsume(
      serverKey,
      DateTime.now(),
      pool: rawPool is String ? rawPool : null,
    );
    if (denial != null) {
      throw McpRpcException(
        -32000,
        'sampling 配额超限（滑动窗口次数制）',
        data: {
          'hint': 'retry after ${denial.inSeconds}s',
          'retry_after_seconds': denial.inSeconds,
        },
      );
    }
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

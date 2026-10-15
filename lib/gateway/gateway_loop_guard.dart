/// 网关环路防护（A2 止血项，SA-Q5 双保险）。
///
/// 背景：`:8766` 网关已生产对外开放（G1~G3），而入站链路零环路防护——
/// 一旦 PC 经网关调本地插件、插件逻辑又反向打回 `:8766`，即成循环风暴
/// （CPU/连接池耗尽 → 闪退）。属「暴露先于防护」的 P0 负债。
///
/// **双保险判据**：
/// 1. **主防线 = 入站 traceId 在途集合（引用计数）**——同一 traceId 在本网关
///    尚有在途实例，且该请求是被转发出来的（`hopCount > 0`）→ 判为嵌套回环。
///    纯本地闭环，不依赖下游透传任何字段；
/// 2. **兜底 = hop_count 深度上限**——即便下游重置 traceId，深度超限仍熔断
///    （防扇出放大）。
///
/// **判据为什么是「traceId + hop>0」而不是「traceId + reqId」**：
/// - 平级并发（PC 一轮触发 3 个 tools/call，客户端常在同一批请求头里复用
///   同一个 Trace-ID 表示同一 Agent Turn）的入站 hopCount 缺省 0 → 永不误杀；
/// - 回环请求由下游重新发起，JSON-RPC id 多为新值，拿 reqId 参与 key 会漏判。
library;

/// 环路阻断的 JSON-RPC 错误码（-32000~-32099 为 server error 保留区间）。
const int kGatewayLoopBlockedCode = -32000;

class GatewayLoopGuard {
  GatewayLoopGuard({
    this.maxHops = defaultMaxHops,
    this.ttl = defaultTtl,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 级联深度上限：PC→A→B 放行，B→C 熔断（正常聚合链路深度远小于此）。
  static const int defaultMaxHops = 2;

  /// 在途记录兜底存活时长：[release] 之外的边缘异常（客户端强断 / 未捕获
  /// 异常 / 超时）防记录永久泄漏。取值覆盖 TC12 的 45s 确认窗 + 长任务；
  /// 到期只失去保护（漏判），不会误杀，故取宽不取紧。
  static const Duration defaultTtl = Duration(seconds: 300);

  final int maxHops;
  final Duration ttl;
  final DateTime Function() _clock;

  final Map<String, _InFlight> _inFlight = {};
  var _seq = 0;

  /// 在途 traceId 数（观测/测试用）。
  int get inFlightCount => _inFlight.length;

  /// 生成入站 traceId（请求未带 `X-Mcp-Trace-Id` 时网关自派）。
  String newTraceId() => 'gw-${_clock().microsecondsSinceEpoch}-${_seq++}';

  /// 入站判定：`null` = 放行；非 null = 拒绝原因（调用方按协议错误回帧）。
  String? checkInbound({required String traceId, required int hopCount}) {
    _sweep();
    if (hopCount > maxHops) {
      return 'hop_count=$hopCount 超过上限 $maxHops（级联过深，疑似环路）';
    }
    if (hopCount > 0 && _inFlight.containsKey(traceId)) {
      return 'traceId=$traceId 已有在途实例且 hop_count=$hopCount（嵌套回环）';
    }
    return null;
  }

  /// 登记在途（引用计数：平级并发复用同一 traceId 时各自计一份，任一在途
  /// 即视为「父请求未结束」）。
  void acquire(String traceId) {
    _sweep();
    final cur = _inFlight[traceId];
    if (cur == null) {
      _inFlight[traceId] = _InFlight(1, _clock());
    } else {
      cur.refs++;
    }
  }

  /// 释放在途——**必须由调用方在 finally 中调用**，覆盖成功 / 失败 / 超时 /
  /// 客户端强断四条路径（仅靠正常返回位释放会在长连接中断时泄漏）。
  void release(String traceId) {
    final cur = _inFlight[traceId];
    if (cur == null) return;
    if (--cur.refs <= 0) _inFlight.remove(traceId);
  }

  /// TTL 惰性驱逐：不启 Timer（测试零 pending timer），登记/判定时顺带扫。
  void _sweep() {
    if (_inFlight.isEmpty) return;
    final now = _clock();
    _inFlight.removeWhere((_, v) => now.difference(v.since) > ttl);
  }
}

class _InFlight {
  _InFlight(this.refs, this.since);

  int refs;
  final DateTime since;
}

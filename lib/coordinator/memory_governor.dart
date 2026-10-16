/// 记忆治理器（context-stepped-pruning §6，内核层）：记忆区「冷热分层 +
/// 增量压实」策略的单点 owner——
///
/// - [journal]（MemoryJournal）：frozenBase 字节冻结 + pendingDeltas
///   Append-Only 传输态投影（store 仍是单点真相）；
/// - **Tick 判定**（§6.4，与阶梯截断同频同源）：滑窗高水位 / TTL 机会主义
///   （≥5 分钟缓存注定失效，白嫖冷启动压实）/ transcript 体量突发兜底；
/// - **单向栅栏**（§6.7）：Run 边界 [assembleSystemTail] 读快照，Run 内
///   [record] 只写 pending 池，下一 Run 才生效。
///
/// 落点纪律（window-kernel-split）：本类在 coordinator 层、纯 Dart 零 Flutter
/// 依赖（conversation_archive 同门禁口径），窗口（chat_page）只负责测量
/// transcript（轮数/体量）并投影渲染结果。实例随会话生灭（切会话 reset()）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../sandbox/memory_store.dart';
import 'memory_journal.dart';

/// Tick 轮次高水位默认值 = 阶梯截断触发线（windowRounds + windowStep 同源，
/// 12；与 context_governor 的 kWindowRounds + kWindowStep 对账）。
const int kDefaultTickRoundWatermark = 12;

/// Token 突发兜底预算（轮数未到但体量爆窗时强制 Tick；字符级粗估口径）。
const int kDefaultTickTokenBudget = 8000;

/// TTL 机会主义压实窗口（分钟）：服务商 ephemeral 缓存的典型失效阈值。
const int kDefaultTtlMinutes = 5;

class MemoryGovernor {
  MemoryGovernor({
    this.tickRoundWatermark = kDefaultTickRoundWatermark,
    this.tickTokenBudget = kDefaultTickTokenBudget,
    this.ttlMinutes = kDefaultTtlMinutes,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 传输态投影本体（frozenBase + pendingDeltas）。
  final MemoryJournal journal = MemoryJournal();

  final int tickRoundWatermark;
  final int tickTokenBudget;
  final int ttlMinutes;
  final DateTime Function() _clock;

  /// 上次 Run 结束时刻（TTL 判定起点；null = 本会话尚无已完成 Run）。
  DateTime? _lastRunEndedAt;

  /// 周期锚点是否已建立：与「快照内容为空」是两个语义——空 store 合法渲染
  /// 出空串快照（锚点已建），此后周期按 Tick 条件走，不得每 Run 重压实。
  var _anchored = false;

  /// Tick 判定（§6.4）：三条件任一命中即压实。[transcriptRounds] /
  /// [transcriptTokens] 由窗口侧测量传入（本类不接触 transcript 本体）。
  bool decideTick({
    required int transcriptRounds,
    required int transcriptTokens,
  }) {
    if (!_anchored && journal.frozenBase.isEmpty) return true; // 首装配必压实
    if (transcriptRounds > tickRoundWatermark) return true;
    if (transcriptTokens > tickTokenBudget) return true;
    final last = _lastRunEndedAt;
    return last != null && _clock().difference(last).inMinutes >= ttlMinutes;
  }

  /// Run 边界装配（§6.4/§6.5）：Tick 命中 → store 全量现渲染压实快照并清空
  /// 增量；返回 systemTail（= 冻结快照本体，周期内字节级不变）。
  Future<String> assembleSystemTail({
    required MemoryStore store,
    required List<String> serverScopes,
    required int transcriptRounds,
    required int transcriptTokens,
  }) async {
    if (decideTick(
      transcriptRounds: transcriptRounds,
      transcriptTokens: transcriptTokens,
    )) {
      journal.compact(
        await memoryPromptSection(store, serverScopes: serverScopes),
      );
    }
    _anchored = true;
    return journal.frozenBase;
  }

  /// 周期内变更入口（Run 内 onCapsule 只写；单向栅栏）。session 域不注入
  /// prompt（§6.1 现状缺口），窗口侧在回调处过滤后再入本口。
  void record({
    required String action,
    required String scope,
    required String key,
    required String value,
  }) =>
      journal.record(
        action: action,
        scope: scope,
        key: key,
        value: value,
      );

  /// 增量区渲染（squash 折叠后）：供窗口侧以 contextFooter 沉底注入。
  String renderFooter() => journal.renderDeltas();

  /// Run 收尾打时间戳（TTL 机会主义压实的判定起点）。
  void markRunEnded() => _lastRunEndedAt = _clock();

  /// 切会话重置（§6.2：传输态随会话生灭，周期锚点归零）。
  void reset() {
    journal.compact('');
    _lastRunEndedAt = null;
    _anchored = false;
  }

  /// 测试观察口（TTL 注入 clock 后的断言便利）。
  @visibleForTesting
  DateTime? get lastRunEndedAt => _lastRunEndedAt;
}

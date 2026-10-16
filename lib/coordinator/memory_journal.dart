/// 记忆增量日志（context-stepped-pruning §6）：传输态投影——展示视图
/// （MemoryStore/wsStates + UI 胶囊）与传输协议（LLM 上下文）解耦的
/// Append-Only 补丁层。
///
/// - **frozenBase**：上次 Tick 压实时 `memoryPromptSection` 的全量渲染文本，
///   周期内字节级不变（前缀缓存锚点）；
/// - **pendingDeltas**：本周期内新变更日志，只追加禁重排（SET/OVERRIDE/DEL
///   显式标记行，兼容端侧小模型；胶囊 undo 走 DEL——append-only 连撤销覆盖）；
/// - **Squash**（§6.6）：组装时 last-wins 折叠同 key 多条——delta 处尾部
///   动荡区，折叠零缓存代价，消除端侧模型同 key 冲突值共存（降幻觉）；
/// - **压实**（§6.4）：Tick（滑窗截断/TTL/Token 突发）时以 store 全量现渲染
///   覆盖 frozenBase 并清空 deltas，与阶梯截断同帧（前缀反正要断一次）。
///
/// 纯 Dart 零 Flutter 依赖（conversation_archive 同门禁口径）。
library;

/// 单条增量：[op] ∈ set | override | del。
class MemoryDelta {
  const MemoryDelta({
    required this.op,
    required this.scope,
    required this.key,
    required this.value,
  });

  final String op;
  final String scope;
  final String key;
  final String value;
}

class MemoryJournal {
  /// 上次压实时的记忆区渲染文本（周期内字节级不变；空串 = 尚无记忆区）。
  String frozenBase = '';

  final List<MemoryDelta> _deltas = [];

  bool get hasDeltas => _deltas.isNotEmpty;

  int get deltaCount => _deltas.length;

  /// 追加一条变更（Append-Only：禁重排禁原地改）。
  ///
  /// [action] 为模型事实的 action（`upsert|remove`）；op 判定：remove → DEL；
  /// upsert 且本周期内该 (scope,key) 已有记录 → OVERRIDE，否则 SET。
  void record({
    required String action,
    required String scope,
    required String key,
    required String value,
  }) {
    if (action == 'remove') {
      _deltas.add(MemoryDelta(
        op: 'del',
        scope: scope,
        key: key,
        value: '',
      ));
      return;
    }
    final seen = _deltas.any((d) => d.scope == scope && d.key == key);
    _deltas.add(MemoryDelta(
      op: seen ? 'override' : 'set',
      scope: scope,
      key: key,
      value: value,
    ));
  }

  /// Squash（§6.6）：last-wins 折叠——同 (scope,key) 只保留最终有效态，
  /// 顺序按该 key 首次出现序（追加纪律的只读视图，不改日志本体）。
  /// 归并后的单行 op 统一为 `set`（SET/OVERRIDE 的区分只在原始日志里有意义，
  /// 折叠后单行即既定事实）；`del` 终态保留。
  List<MemoryDelta> squashed() {
    // Dart Map 赋值保留**首次插入序**、值取最后一次写入——恰为
    // 「首现序 + last-wins」语义，单次前向遍历完成折叠。
    final map = <String, MemoryDelta>{};
    for (final d in _deltas) {
      map['${d.scope}.${d.key}'] =
          d.op == 'del'
              ? d
              : MemoryDelta(
                  op: 'set', scope: d.scope, key: d.key, value: d.value);
    }
    return map.values.toList(growable: false);
  }

  /// 渲染增量区（沉底注入用，§6.5）：空返回空串。
  String renderDeltas() {
    final lines = [
      for (final d in squashed())
        switch (d.op) {
          'del' => '- DEL ${d.scope}.${d.key}',
          'override' => '- OVERRIDE ${d.scope}.${d.key} = ${d.value}',
          _ => '- SET ${d.scope}.${d.key} = ${d.value}',
        },
    ];
    return lines.isEmpty ? '' : '[Recent Memory Updates]\n${lines.join('\n')}';
  }

  /// Tick 压实（§6.4）：以 store 全量现渲染覆盖快照、清空增量。
  void compact(String renderedBase) {
    frozenBase = renderedBase;
    _deltas.clear();
  }
}

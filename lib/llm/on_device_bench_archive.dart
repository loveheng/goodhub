/// 端侧适用性对照表的采集行模型与归档渲染（task-capability W2 · S11）。
///
/// **行契约（键集固定）**：采集行 = 一条用例的一次实测结果；归档表与后续
/// 消费面（S12 `assets/model-specs.json` 任务亲和性字段）按此键集解析，
/// **缺项即坏行**——采集行不得有可空字段（实测值缺失用 `0` 显式表达，
/// 失败用例另带 `error` 字段）。
///
/// **归档口径**：格式对齐既有真机基准归档（段 × 任务类型 × 实测代价），
/// 增列**产出质量档**（机械判据，见 `on_device_bench_suite.dart`）——既有
/// 归档只记代价（延迟/吞吐/内存/热），本表补「代价换来的产出能不能用」。
library;

/// 采集行必需键集（缺任一 = 坏行，归档器拒收）。
const List<String> kOnDeviceBenchRowKeys = [
  'model',
  'ctx',
  'segment',
  'taskType',
  'case',
  'tier',
  'promptChars',
  'ttftMs',
  'tpotMs',
  'tokPerSec',
  'chars',
  'quality',
  'score',
];

/// 采集行（一次用例实测）。
class OnDeviceBenchRow {
  const OnDeviceBenchRow({
    required this.model,
    required this.ctx,
    required this.segment,
    required this.taskType,
    required this.caseId,
    required this.tier,
    required this.promptChars,
    required this.ttftMs,
    required this.tpotMs,
    required this.tokPerSec,
    required this.chars,
    required this.quality,
    required this.score,
    this.note = '',
    this.error = '',
  });

  /// 模型目录名（资产身份锚点）。
  final String model;

  /// 模型上下文窗口（token；未标注 = 0）。
  final int ctx;

  /// 测量段（`pass=auto` = Runner 自裁 / `pass=gpu` = 强制 GPU 档）。
  final String segment;

  /// 任务类型标识（taxonomy）。
  final String taskType;

  /// 用例标识。
  final String caseId;

  /// 输入体量档（`short` / `long`）。
  final String tier;

  /// 输入正文字符数（体量压力口径；中文 ≈1.3 字/token）。
  final int promptChars;

  /// 首 token 延迟（ms）。
  final int ttftMs;

  /// 每 token 间隔（ms/chunk 近似）。
  final double tpotMs;

  /// 吞吐（tok/s 近似）。
  final double tokPerSec;

  /// 产出字数。
  final int chars;

  /// 产出质量档（`pass` / `degraded` / `fail`；失败用例 = `fail`）。
  final String quality;

  /// 事实命中率（0..1）。
  final double score;

  /// 判据留痕。
  final String note;

  /// 失败原因（正常用例为空串）。
  final String error;

  /// 行 → JSON（键序与 [kOnDeviceBenchRowKeys] 一致，便于人读）。
  Map<String, Object?> toJson() => {
    'model': model,
    'ctx': ctx,
    'segment': segment,
    'taskType': taskType,
    'case': caseId,
    'tier': tier,
    'promptChars': promptChars,
    'ttftMs': ttftMs,
    'tpotMs': tpotMs,
    'tokPerSec': tokPerSec,
    'chars': chars,
    'quality': quality,
    'score': score,
    'note': note,
    'error': error,
  };

  /// JSON → 行；键集不合规或类型不符返 null（坏行不进表）。
  static OnDeviceBenchRow? fromJson(Map<String, dynamic> json) {
    if (validateBenchRow(json) != null) return null;
    return OnDeviceBenchRow(
      model: json['model'] as String,
      ctx: (json['ctx'] as num).toInt(),
      segment: json['segment'] as String,
      taskType: json['taskType'] as String,
      caseId: json['case'] as String,
      tier: json['tier'] as String,
      promptChars: (json['promptChars'] as num).toInt(),
      ttftMs: (json['ttftMs'] as num).toInt(),
      tpotMs: (json['tpotMs'] as num).toDouble(),
      tokPerSec: (json['tokPerSec'] as num).toDouble(),
      chars: (json['chars'] as num).toInt(),
      quality: json['quality'] as String,
      score: (json['score'] as num).toDouble(),
      note: (json['note'] as String?) ?? '',
      error: (json['error'] as String?) ?? '',
    );
  }
}

/// 坏行原因（null = 合法行）；键缺失 / 类型不符 → 非 null。
String? validateBenchRow(Map<String, dynamic> row) {
  for (final key in kOnDeviceBenchRowKeys) {
    if (!row.containsKey(key)) return '缺键 $key';
  }
  const stringKeys = [
    'model',
    'segment',
    'taskType',
    'case',
    'tier',
    'quality',
  ];
  for (final key in stringKeys) {
    if (row[key] is! String) return '类型错 $key';
  }
  const numKeys = [
    'ctx',
    'promptChars',
    'ttftMs',
    'tpotMs',
    'tokPerSec',
    'chars',
    'score',
  ];
  for (final key in numKeys) {
    if (row[key] is! num) return '类型错 $key';
  }
  return null;
}

/// 任务类型的适用档位（**机械判定**，非主观）。
///
/// 判据：全失败 = 不可用；有失败有成功 = 部分不可用；全合格 = 可用；
/// 其余（合格 + 降级）= 降级可用。
String benchApplicability(List<OnDeviceBenchRow> rows) {
  if (rows.isEmpty) return '未采集';
  final failed = rows
      .where((r) => r.quality == 'fail' || r.error.isNotEmpty)
      .length;
  final passed = rows.where((r) => r.quality == 'pass').length;
  if (failed == rows.length) return '不可用';
  if (failed > 0) return '部分不可用';
  if (passed == rows.length) return '可用';
  return '降级可用';
}

/// 数值格式化（浮点保留一位小数；区间用 `~` 连接）。
String _num1(double v) => v.toStringAsFixed(1);

String _range(num min, num max) {
  String f(num v) => v is int ? '$v' : _num1(v.toDouble());
  return min == max ? f(min) : '${f(min)}~${f(max)}';
}

/// 采集行集合 → 对照表 markdown（格式对齐既有真机基准归档）。
///
/// [device] / [model] 为抬头事实（真机与资产身份）；缺省不写该行。
/// 汇总分两层：**分段汇总**（段 × 任务类型，区间同段内可比）与
/// **任务类型总览**（跨段，产出适用档位）。
String renderBenchArchive(
  List<OnDeviceBenchRow> rows, {
  String? device,
  String? model,
  String? collectedAt,
}) {
  final buf = StringBuffer();
  buf.writeln('# 端侧适用性对照表（真机采集）');
  buf.writeln();
  buf.writeln(
    '> 采集面 = `lib/llm/on_device_bench.dart` 任务套件扫描'
    '（`--dart-define=ON_DEVICE_BENCH_TASK_SUITE=true`）；'
    '口径 = 首 token 延迟（TTFT）/ 吞吐（tok/s）/ 上下文体量档 / '
    '产出质量档（机械判据，`lib/llm/on_device_bench_suite.dart`）。',
  );
  if (device != null && device.isNotEmpty) buf.writeln('> 真机：$device');
  if (model != null && model.isNotEmpty) buf.writeln('> 资产：$model');
  if (collectedAt != null && collectedAt.isNotEmpty) {
    buf.writeln('> 采集时间：$collectedAt');
  }
  buf.writeln();

  buf.writeln('## 逐用例');
  buf.writeln();
  buf.writeln(
    '| 段 | 任务类型 | 用例 | 体量档 | 输入字数 | TTFT(ms) | TPOT(ms) | tok/s | '
    '产出字数 | 质量档 | 命中率 | 备注 |',
  );
  buf.writeln('|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (final r in rows) {
    final note = r.error.isNotEmpty ? '失败：${r.error}' : r.note;
    buf.writeln(
      '| ${r.segment} | ${r.taskType} | ${r.caseId} | ${r.tier} | '
      '${r.promptChars} | ${r.ttftMs} | ${_num1(r.tpotMs)} | '
      '${_num1(r.tokPerSec)} | ${r.chars} | ${r.quality} | '
      '${_num1(r.score)} | $note |',
    );
  }
  buf.writeln();

  buf.writeln('## 分段汇总（段 × 任务类型）');
  buf.writeln();
  buf.writeln(
    '| 段 | 任务类型 | 用例数 | 合格 | 降级 | 不可用 | TTFT 区间(ms) | '
    'tok/s 区间 | 适用档位 |',
  );
  buf.writeln('|---|---|---|---|---|---|---|---|---|');
  final bySegmentType = <String, List<OnDeviceBenchRow>>{};
  for (final r in rows) {
    bySegmentType.putIfAbsent('${r.segment}|${r.taskType}', () => []).add(r);
  }
  for (final entry in bySegmentType.entries) {
    final parts = entry.key.split('|');
    buf.writeln(_summaryRow(parts[0], parts[1], entry.value));
  }
  buf.writeln();

  buf.writeln('## 任务类型总览（跨段 · 适用档位）');
  buf.writeln();
  buf.writeln('| 任务类型 | 用例数 | 合格 | 降级 | 不可用 | 适用档位 |');
  buf.writeln('|---|---|---|---|---|---|');
  final byType = <String, List<OnDeviceBenchRow>>{};
  for (final r in rows) {
    byType.putIfAbsent(r.taskType, () => []).add(r);
  }
  for (final entry in byType.entries) {
    final group = entry.value;
    final pass = group.where((r) => r.quality == 'pass').length;
    final degraded = group.where((r) => r.quality == 'degraded').length;
    final fail = group.length - pass - degraded;
    buf.writeln(
      '| ${entry.key} | ${group.length} | $pass | $degraded | $fail | '
      '${benchApplicability(group)} |',
    );
  }
  return buf.toString();
}

/// 分段汇总行（段 × 任务类型）。
String _summaryRow(
  String segment,
  String taskType,
  List<OnDeviceBenchRow> group,
) {
  final ttftMin = group.map((r) => r.ttftMs).reduce((a, b) => a < b ? a : b);
  final ttftMax = group.map((r) => r.ttftMs).reduce((a, b) => a > b ? a : b);
  final tokMin = group.map((r) => r.tokPerSec).reduce((a, b) => a < b ? a : b);
  final tokMax = group.map((r) => r.tokPerSec).reduce((a, b) => a > b ? a : b);
  final pass = group.where((r) => r.quality == 'pass').length;
  final degraded = group.where((r) => r.quality == 'degraded').length;
  final fail = group.length - pass - degraded;
  return '| $segment | $taskType | ${group.length} | $pass | $degraded | $fail | '
      '${_range(ttftMin, ttftMax)} | ${_range(tokMin, tokMax)} | '
      '${benchApplicability(group)} |';
}

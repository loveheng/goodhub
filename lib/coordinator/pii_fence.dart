/// N7 出站隐私围栏内核（M2-T5a，2026-10-11 拍板 D1-D5）。
///
/// 职责边界（架构 §12 隐私围栏）：正则遮蔽 + 反向映射还原的**纯内核**——
/// 挂点 = 云引擎装饰器（T5b 接线，本文件不做引擎装配）：
/// - D1 单咽喉：装饰器对 engine.send 全量出站消息遮蔽；端侧/局域网回环不设防；
/// - D2 会话粒度内存态：一次 Run 一个 [PiiRedactionSession]，同值同占位符
///   跨轮稳定，纯内存不落盘，会话结束即弃；
/// - D3 基础四类：手机号 / 邮箱 / 身份证（18 位含校验位）/ 银行卡（13-19 位
///   过 Luhn）；地址、人名等非结构化 PII 归端侧模型层（T7+，本层不做）；
/// - 占位符 `[手机号1]` 型类型标注 + 按类型首次出现顺序编号；
/// - 遮蔽运算走 Worker Isolate（§11 CPU 密集隔离）+ 3s 超时守卫（防正则
///   灾难回溯拖死主 Isolate；超时后底层 Isolate 自然跑完丢弃，Isolate.run
///   无取消 API，M2 接受该罕见浪费）；
/// - D4 失败语义：遮蔽操作失败抛 [PiiMaskException]——**严禁静默放行**
///   （DEGRADE 禁区），拦截/确认 UX 由装饰器与宿主实现（T5b/c）。
library;

import 'dart:async';
import 'dart:isolate';

/// 遮蔽失败（Isolate 异常/超时）——调用方必须拦截发送，禁止吞掉继续明文出站。
class PiiMaskException implements Exception {
  const PiiMaskException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'PiiMaskException: $message';
}

/// 一次遮蔽运算的产出。
class PiiRedactionOutput {
  const PiiRedactionOutput({
    required this.text,
    required this.newEntries,
    required this.maskedCount,
  });

  /// 遮蔽后的文本。
  final String text;

  /// 本次新登记的 value → placeholder（调用方并入会话映射）。
  final Map<String, String> newEntries;

  /// 本次命中的 PII 片段总数（含复用既有映射的命中）。
  final int maskedCount;
}

/// 会话级 PII 映射与遮蔽/还原门面（D2：一次 Run 一个实例）。
class PiiRedactionSession {
  static const Duration isolateTimeout = Duration(seconds: 3);

  /// 快速门：四类 PII（手机号/身份证/银行卡=纯数字，邮箱=必有 @）的必要条件。
  static final RegExp _quickGate = RegExp(r'[0-9@]');

  final Map<String, String> _valueToPlaceholder = {};

  /// 当前映射快照（value → placeholder，如 `13800138000` → `[手机号1]`）。
  Map<String, String> get mappings => Map.unmodifiable(_valueToPlaceholder);

  /// 反向映射快照（placeholder → value，还原用）。
  Map<String, String> get reverseMappings => {
        for (final e in _valueToPlaceholder.entries) e.value: e.key,
      };

  /// 遮蔽一段文本（Worker Isolate 执行 + 超时守卫）。
  ///
  /// 已知值复用既有占位符（同值同号）；新值按类型计数器续号并登记。
  /// 任何失败抛 [PiiMaskException]（含超时），不降级、不返回原文。
  Future<PiiRedactionOutput> mask(String text) async {
    if (text.isEmpty) {
      return const PiiRedactionOutput(
          text: '', newEntries: {}, maskedCount: 0);
    }
    // 快速门：四类 PII 均含数字或 '@'（邮箱），二者皆无的文本零命中——
    // 免 Isolate 直返原文（纯性能短路，语义与 redactSync 全量扫描等价）。
    if (!_quickGate.hasMatch(text)) {
      return PiiRedactionOutput(text: text, newEntries: const {}, maskedCount: 0);
    }
    final PiiRedactionOutput out;
    try {
      // 已知映射传值进 Isolate（Map 可 send）；会话映射只在主 Isolate 增量合并。
      final known = Map.of(_valueToPlaceholder);
      out = await Isolate.run(() => redactSync(text, known))
          .timeout(isolateTimeout);
    } on TimeoutException catch (e) {
      throw PiiMaskException('PII 遮蔽超时（${isolateTimeout.inSeconds}s）', e);
    } on Object catch (e) {
      throw PiiMaskException('PII 遮蔽失败: $e', e);
    }
    _valueToPlaceholder.addAll(out.newEntries);
    return out;
  }

  /// 反向还原：把文本中的已知占位符替换回原值（同步纯替换，主 Isolate 即可）。
  ///
  /// 只替换映射表中存在的占位符；未知 `[类型N]` 字面量原样保留（模型幻觉
  /// 占位符不猜测还原）。占位符含结尾 `]`，字面替换对 `[手机号1]` vs
  /// `[手机号10]` 天然无前缀误伤。
  String restore(String text) {
    if (text.isEmpty || _valueToPlaceholder.isEmpty) return text;
    var out = text;
    for (final e in _valueToPlaceholder.entries) {
      out = out.replaceAll(e.value, e.key);
    }
    return out;
  }

  /// 流式还原器：处理占位符被流式 delta 切开的场景（D5 还原面①）。
  PiiStreamRestorer streamRestorer() => PiiStreamRestorer(this);
}

/// 流式反向还原：外发前缓冲，保证占位符完整后整体还原外发。
///
/// 算法：对缓冲文本找最后一个 `[`——其前缀（head）可安全还原外发；自 `[`
/// 起的尾部（tail）若仍是某占位符的未完前缀则扣留等后续 delta，否则可外发。
/// tail 出现首个 `]` 即成完整括号组：命中映射表则还原，否则按字面量外发
/// （占位符内部不含 `]`，首个 `]` 前后均不可能有更长占位符）。
class PiiStreamRestorer {
  PiiStreamRestorer(this._session);

  final PiiRedactionSession _session;
  final StringBuffer _buf = StringBuffer();

  /// 喂入一个 delta，返回此刻可安全外发的还原后文本（可能为空串）。
  String push(String delta) {
    if (delta.isEmpty) return '';
    _buf.write(delta);
    final raw = _buf.toString();
    final br = raw.lastIndexOf('[');
    if (br < 0) {
      _buf.clear();
      return _session.restore(raw);
    }
    final head = _session.restore(raw.substring(0, br));
    final tail = raw.substring(br);
    final close = tail.indexOf(']');
    if (close < 0) {
      if (_isViablePrefix(tail)) {
        _buf
          ..clear()
          ..write(tail);
        return head;
      }
      _buf.clear();
      return head + tail;
    }
    // tail 已含完整括号组：命中则还原，未命中为字面量；其后无更多 `[`，
    // 无未完占位符，可全量外发。
    _buf.clear();
    final cand = tail.substring(0, close + 1);
    final rest = tail.substring(close + 1);
    final value = _session.reverseMappings[cand];
    return head + (value ?? cand) + rest;
  }

  /// 流收尾：不再有后续 delta，缓冲内全部外发（未完括号组按字面量）。
  String flush() {
    final raw = _buf.toString();
    _buf.clear();
    return _session.restore(raw);
  }

  /// tail 是否仍可能长成映射表中的某个占位符（占位符均以 `[` 开头 `]` 结尾）。
  bool _isViablePrefix(String tail) {
    for (final placeholder in _session.reverseMappings.keys) {
      if (placeholder.startsWith(tail)) return true;
    }
    return false;
  }
}

/// 正则遮蔽纯函数（可在 Isolate 内执行：不触主 Isolate 状态）。
///
/// [known] 为既有 value → placeholder 映射；返回遮蔽后文本与新增条目。
PiiRedactionOutput redactSync(
  String text,
  Map<String, String> known,
) {
  final spans = <_PiiSpan>[];
  for (final rule in _rules) {
    for (final m in rule.pattern.allMatches(text)) {
      if (rule.validate != null && !rule.validate!(m.group(0)!)) continue;
      final value = rule.normalize?.call(m.group(0)!) ?? m.group(0)!;
      final span = _PiiSpan(m.start, m.end, value, rule.label);
      if (spans.any((s) => span.overlaps(s))) continue; // 高优先级规则已占
      spans.add(span);
    }
  }
  if (spans.isEmpty) {
    return PiiRedactionOutput(
        text: text, newEntries: const {}, maskedCount: 0);
  }
  spans.sort((a, b) => a.start.compareTo(b.start));

  // 类型计数器续号：同值同号（D2），新值按该类型已有最大编号 +1。
  final counters = <String, int>{};
  for (final p in known.values) {
    final m = _placeholderPattern.firstMatch(p);
    if (m != null) {
      final label = m.group(1)!;
      counters[label] =
          (counters[label] ?? 0) > int.parse(m.group(2)!)
              ? counters[label]!
              : int.parse(m.group(2)!);
    }
  }
  final newEntries = <String, String>{};
  final out = StringBuffer();
  var cursor = 0;
  for (final s in spans) {
    out.write(text.substring(cursor, s.start));
    final placeholder =
        known[s.value] ?? _newPlaceholder(s.label, counters, newEntries, s.value);
    out.write(placeholder);
    cursor = s.end;
  }
  out.write(text.substring(cursor));
  return PiiRedactionOutput(
    text: out.toString(),
    newEntries: newEntries,
    maskedCount: spans.length,
  );
}

String _newPlaceholder(
  String label,
  Map<String, int> counters,
  Map<String, String> newEntries,
  String value,
) {
  final n = (counters[label] ?? 0) + 1;
  counters[label] = n;
  final placeholder = '[$label$n]';
  newEntries[value] = placeholder;
  return placeholder;
}

final RegExp _placeholderPattern = RegExp(r'^\[(.+?)(\d+)\]$');

class _PiiSpan {
  const _PiiSpan(this.start, this.end, this.value, this.label);

  final int start;
  final int end;
  final String value;
  final String label;

  bool overlaps(_PiiSpan other) => start < other.end && other.start < end;
}

class _PiiRule {
  const _PiiRule({
    required this.label,
    required this.pattern,
    this.validate,
    this.normalize,
  });

  final String label;
  final RegExp pattern;

  /// 命中后的二次校验（身份证校验位 / 银行卡 Luhn）；false = 放过不遮。
  final bool Function(String value)? validate;

  /// 命中后的值归一化（默认原样）：分组书写的数字类取纯数字做 value，
  /// 与连续书写同值同号（D2 一致性）；跨度和还原行为不受影响。
  final String Function(String value)? normalize;
}

/// D3 基础四类（优先级序：先命中者占跨度的规则胜出）。
///
/// 数字类规则以字母数字邻位界定（避免从长数字串/编码 token 中截取假阳性）；
/// 分组书写归一化（2026-10-11 T7 调参拍板）：手机号 3-4-4、银行卡 3-5 位任意
/// 分组（校验按剥隔后纯数字），分隔符限空格/制表/全角空格/连字符——换行不作
/// 分隔符（竖排短数字列不误并）；值归一化为纯数字，与连续书写同值同号（D2）。
// RegExp 非常量构造，规则表只能 final（热路径仅初始化一次）。
final List<_PiiRule> _rules = [
  _PiiRule(
    label: '邮箱',
    pattern: RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
  ),
  _PiiRule(
    label: '身份证',
    pattern: RegExp(r'(?<![0-9A-Za-z])\d{17}[0-9Xx](?![0-9A-Za-z])'),
    validate: _validIdChecksum,
  ),
  _PiiRule(
    label: '手机号',
    pattern: RegExp(r'(?<![0-9A-Za-z])1[3-9]\d{9}(?![0-9A-Za-z])'),
  ),
  _PiiRule(
    label: '手机号',
    pattern: RegExp(
        r'(?<![0-9A-Za-z])1[3-9]\d{2}[- \t\u3000]\d{4}[- \t\u3000]\d{4}'
        r'(?![0-9A-Za-z])'),
    normalize: _stripDigitSeparators,
  ),
  _PiiRule(
    label: '银行卡',
    pattern: RegExp(r'(?<![0-9A-Za-z])\d{13,19}(?![0-9A-Za-z])'),
    validate: _luhnValid,
  ),
  _PiiRule(
    label: '银行卡',
    pattern: RegExp(
        r'(?<![0-9A-Za-z])(\d{3,5}[- \t\u3000]){2,6}\d{3,5}(?![0-9A-Za-z])'),
    validate: (v) {
      final digits = _stripDigitSeparators(v);
      return digits.length >= 13 && digits.length <= 19 && _luhnValid(digits);
    },
    normalize: _stripDigitSeparators,
  ),
];

String _stripDigitSeparators(String v) => v.replaceAll(RegExp(r'[- \t\u3000]'), '');

/// GB 11643-1999 18 位身份证校验位。
bool _validIdChecksum(String id) {
  const weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  const codes = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];
  var sum = 0;
  for (var i = 0; i < 17; i++) {
    sum += int.parse(id[i]) * weights[i];
  }
  return codes[sum % 11] == id[17].toUpperCase();
}

/// Luhn 算法（银行卡尾位校验）。
bool _luhnValid(String digits) {
  var sum = 0;
  var alt = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var d = int.parse(digits[i]);
    if (alt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    alt = !alt;
  }
  return sum % 10 == 0;
}

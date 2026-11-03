/// 端侧适用性对照表采集套件（task-capability W2 · S11）。
///
/// **定位**：`lib/llm/on_device_bench.dart` 是「怎么测」的驱动器；本件是
/// **「测什么」的规格源**——任务类型分类（taxonomy）+ 每类任务的用例集 +
/// **机械质量判据**。采集行模型与归档渲染在 `on_device_bench_archive.dart`；
/// 数据最终落 S12 的 `assets/model-specs.json` 任务亲和性字段。
///
/// **红线**：
/// ① **质量档必须机械可判**——判据 = 事实命中 / 格式可解析 / 结构合规，
///    禁「人工看着还行」入表（人工只做最终采信，不做逐例打分）；
/// ② 任务类型是**能力需求面**的分类（对齐能力需求声明的结构化产出 /
///    体量 / 时效三维），不是按实现难度分类；
/// ③ **纯 Dart、无平台依赖**（可单测）——禁 import 端侧实现件。
library;

import 'dart:convert';

/// 产出形态（任务类型 → 端侧需要的能力面：自由文本 vs 结构化产出）。
enum OnDeviceBenchOutputShape { text, json }

/// 输入体量档（对齐既有基准场景：short ≈256ctx / long ≈2Kctx）。
enum OnDeviceBenchInputTier {
  short('short'),
  long('long');

  const OnDeviceBenchInputTier(this.id);

  /// 稳定标识（归档表与 `assets/model-specs.json` 任务亲和性字段的键面）。
  final String id;
}

/// 产出质量档（**机械判据**三档）。
///
/// 与端侧三档降级（failFast / 切云 / 截断）不是同一维度：本枚举判
/// **产出质量**（产出是否符合任务要求），不判引擎可用性。
enum OnDeviceBenchQuality {
  pass('pass'),
  degraded('degraded'),
  fail('fail');

  const OnDeviceBenchQuality(this.id);

  /// 稳定标识（归档表与消费面键面）。
  final String id;
}

/// 任务类型（taxonomy）——对照表的行维度。
enum OnDeviceBenchTaskType {
  qa('qa', '短问答', OnDeviceBenchOutputShape.text),
  summarize('summarize', '摘要', OnDeviceBenchOutputShape.text),
  classify('classify', '分类', OnDeviceBenchOutputShape.text),
  extract('extract', '结构化抽取', OnDeviceBenchOutputShape.json),
  rewrite('rewrite', '改写', OnDeviceBenchOutputShape.text),
  code('code', '代码生成', OnDeviceBenchOutputShape.text),
  multiTurn('multiTurn', '多轮对话', OnDeviceBenchOutputShape.text),
  longDocQa('longDocQa', '长文档问答', OnDeviceBenchOutputShape.text);

  const OnDeviceBenchTaskType(this.id, this.label, this.shape);

  /// 稳定标识（归档表与 `assets/model-specs.json` 任务亲和性字段的键面）。
  final String id;

  /// 中文标签（归档表展示名）。
  final String label;

  /// 期望产出形态——结构化产出任务 = 端侧约束解码承载的适用性证据面
  /// （W3 S17b 的前提校验在此取证）。
  final OnDeviceBenchOutputShape shape;
}

/// 质量判据产物。
class OnDeviceBenchGrade {
  const OnDeviceBenchGrade(this.quality, this.score, this.note);

  /// 质量档。
  final OnDeviceBenchQuality quality;

  /// 事实命中率（0..1；判据口径内可比，跨用例不直接横比）。
  final double score;

  /// 判据留痕（进归档表备注列，人工可复核判据本身）。
  final String note;
}

/// 评分器签名（纯函数：输入 = 模型原始产出，输出 = 质量判据）。
typedef OnDeviceBenchGrader = OnDeviceBenchGrade Function(String output);

/// 对话轮（assistant 轮 = 模拟历史轮次，用于多轮复读观测）。
class OnDeviceBenchTurn {
  const OnDeviceBenchTurn.user(this.content) : role = 'user';

  const OnDeviceBenchTurn.assistant(this.content) : role = 'assistant';

  /// 角色名（`user` / `assistant`）。
  final String role;

  /// 轮次正文。
  final String content;
}

/// 采集用例（一次生成 = 一个用例）。
class OnDeviceBenchCase {
  const OnDeviceBenchCase({
    required this.id,
    required this.taskType,
    required this.tier,
    required this.turns,
    required this.grader,
  });

  /// 用例标识（归档表行键面）。
  final String id;

  /// 任务类型（taxonomy 维度）。
  final OnDeviceBenchTaskType taskType;

  /// 输入体量档（上下文压力维度）。
  final OnDeviceBenchInputTier tier;

  /// 对话轮序列（末轮须为 user——与端侧 Runner 契约一致）。
  final List<OnDeviceBenchTurn> turns;

  /// 机械质量判据。
  final OnDeviceBenchGrader grader;

  /// 输入全文（复读检测基准面）。
  String get inputText => turns.map((t) => t.content).join('\n');
}

/// 事实命中判据（**别名为一组，组内任一命中即算该组命中**）。
///
/// 全部命中 = 合格；部分命中 = 降级；零命中 = 不可用。
/// [maxChars] > 0 时超长降级（啰嗦产出对「可用」是减项）。
OnDeviceBenchGrade gradeFactGroups(
  String output,
  List<List<String>> groups, {
  int maxChars = 0,
}) {
  if (groups.isEmpty) {
    return const OnDeviceBenchGrade(OnDeviceBenchQuality.fail, 0, '判据缺失：事实组为空');
  }
  final hits = groups.where((g) => g.any(output.contains)).length;
  final score = hits / groups.length;
  var quality = score >= 1.0
      ? OnDeviceBenchQuality.pass
      : (score > 0 ? OnDeviceBenchQuality.degraded : OnDeviceBenchQuality.fail);
  var note = 'facts $hits/${groups.length}';
  final len = output.trim().length;
  if (maxChars > 0 && len > maxChars) {
    if (quality == OnDeviceBenchQuality.pass) {
      quality = OnDeviceBenchQuality.degraded;
    }
    note += ' +冗长($len>$maxChars)';
  }
  return OnDeviceBenchGrade(quality, score, note);
}

/// 标签判据：命中标签 = 合格（**只输出标签本身**才算合格）；夹带解释或
/// 超长 = 降级；未命中 = 不可用。
OnDeviceBenchGrade gradeLabel(
  String output,
  List<String> labels, {
  int maxChars = 40,
}) {
  if (!labels.any(output.contains)) {
    return const OnDeviceBenchGrade(OnDeviceBenchQuality.fail, 0, 'label miss');
  }
  final normalized = _normalizeLabel(output);
  if (labels.any((l) => _normalizeLabel(l) == normalized)) {
    return const OnDeviceBenchGrade(OnDeviceBenchQuality.pass, 1.0, 'label 精确');
  }
  final len = normalized.length;
  final tooLong = maxChars > 0 && len > maxChars;
  return OnDeviceBenchGrade(
    OnDeviceBenchQuality.degraded,
    1.0,
    tooLong ? 'label hit +冗长($len>$maxChars)' : 'label hit +夹带($len 字)',
  );
}

/// 标签归一（去尾随标点与空白——「发热。」与「发热」同义）。
String _normalizeLabel(String raw) =>
    raw.trim().replaceAll(RegExp(r'[\s。．.，,、；;：:！!？?]+$'), '');

/// 结构化产出判据：JSON 可解析且字段全对 = 合格；可解析但缺/错 = 降级；
/// 不可解析 = 不可用。
///
/// 字段值为**别名列表**（任一别名命中即算该字段命中）——输出格式差异
/// （日期写法、空格）不该被误判为事实错误。
OnDeviceBenchGrade gradeJsonFields(
  String output,
  Map<String, List<String>> expected,
) {
  final obj = extractJsonObject(output);
  if (obj == null) {
    return const OnDeviceBenchGrade(OnDeviceBenchQuality.fail, 0, 'json 不可解析');
  }
  var matched = 0;
  for (final entry in expected.entries) {
    final value = obj[entry.key];
    if (value is String && entry.value.any(value.contains)) matched++;
  }
  final total = expected.length;
  final score = total == 0 ? 0.0 : matched / total;
  final quality = score >= 1.0
      ? OnDeviceBenchQuality.pass
      : (score > 0 ? OnDeviceBenchQuality.degraded : OnDeviceBenchQuality.fail);
  return OnDeviceBenchGrade(quality, score, 'fields $matched/$total');
}

/// 抽取首个 JSON 对象（模型常裹代码块或前后解释）；不可解析返 null。
Map<String, dynamic>? extractJsonObject(String output) {
  final start = output.indexOf('{');
  final end = output.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(output.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// 复读判据 + 事实命中：命中事实但复读历史轮 = **不可用**（复读产出没有回答
/// 当前问题，不是「降级」）。
OnDeviceBenchGrade gradeNoEcho(
  String output,
  List<List<String>> groups,
  List<String> echoMarkers,
) {
  final echoed = echoMarkers
      .where((m) => m.isNotEmpty && output.contains(m))
      .toList();
  if (echoed.isNotEmpty) {
    return OnDeviceBenchGrade(
      OnDeviceBenchQuality.fail,
      0,
      '复读 ${echoed.length} 处',
    );
  }
  return gradeFactGroups(output, groups);
}

// ── 用例判据（每个任务的「什么算合格」）─────────────────────────────

OnDeviceBenchGrade _qaGrader(String out) => gradeFactGroups(out, const [
  ['8 Elite'],
  ['NPU', '神经', '推理'],
], maxChars: 120);

OnDeviceBenchGrade _summarizeGrader(String out) => gradeFactGroups(out, const [
  ['电池'],
  ['发票'],
  ['开机', '故障'],
], maxChars: 120);

OnDeviceBenchGrade _classifyGrader(String out) =>
    gradeLabel(out, const ['发热', '烫', '温度']);

OnDeviceBenchGrade _extractGrader(String out) => gradeJsonFields(out, const {
  'name': ['林工'],
  'city': ['深圳'],
  'date': ['3月12日', '3 月 12 日', '3月12'],
});

OnDeviceBenchGrade _rewriteGrader(String out) => gradeFactGroups(out, const [
  ['传感器'],
  ['温度', '读数'],
], maxChars: 60);

OnDeviceBenchGrade _codeGrader(String out) => gradeFactGroups(out, const [
  ['fun '],
  ['reverse'],
  ['String', 'string'],
  ['('],
]);

OnDeviceBenchGrade _multiTurnGrader(String out) => gradeNoEcho(
  out,
  const [
    ['王工'],
    ['深圳'],
  ],
  const ['好的，王工。您负责深圳地区的设备维护工作。'],
);

OnDeviceBenchGrade _longDocQaGrader(String out) => gradeFactGroups(out, const [
  ['4500'],
  ['6 小时', '6小时', '六小时', '六 小时'],
], maxChars: 80);

// ── 用例集 ────────────────────────────────────────────────────────

/// 用例集（**taxonomy 每类至少一例**——缺类即对照表缺行）。
abstract final class OnDeviceBenchSuite {
  /// 摘要材料（长体量档：结论事实埋在正文里，padding 追加在后）。
  static const String summarizeMaterial =
      '客户张伟于 3 月 5 日到店反映设备无法开机，工程师检测后确认是电池故障，'
      '已更换电池并完成开机验证；客户随后询问保修凭证的补办流程，'
      '门店告知需提供购买发票原件。';

  /// 长文档材料（长体量档：数值事实埋在正文里）。
  static const String longDocMaterial =
      '设备巡检手册第 3 节说明：备用电源容量为 4500mAh，断电后可维持约 6 小时的'
      '持续供电；充电建议使用随附的 65W 适配器，长时间满载任务须接入外部电源。';

  /// 全部用例（采集顺序 = 短体量在前，避免首轮冷装载抖动污染长体量对比）。
  static const List<OnDeviceBenchCase> cases = [
    OnDeviceBenchCase(
      id: 'qa-short',
      taskType: OnDeviceBenchTaskType.qa,
      tier: OnDeviceBenchInputTier.short,
      turns: [OnDeviceBenchTurn.user('请用一句话介绍骁龙 8 Elite 的 NPU。')],
      grader: _qaGrader,
    ),
    OnDeviceBenchCase(
      id: 'classify-short',
      taskType: OnDeviceBenchTaskType.classify,
      tier: OnDeviceBenchInputTier.short,
      turns: [
        OnDeviceBenchTurn.user(
          '判断下面这条反馈属于哪一类'
          '（屏幕/电池/发热/系统），只输出类别名：\n反馈：手机充电时烫得厉害，屏幕显示正常。',
        ),
      ],
      grader: _classifyGrader,
    ),
    OnDeviceBenchCase(
      id: 'extract-short',
      taskType: OnDeviceBenchTaskType.extract,
      tier: OnDeviceBenchInputTier.short,
      turns: [
        OnDeviceBenchTurn.user(
          '从下面文字中抽取字段，'
          '只输出 JSON 对象，键为 name/city/date：\n文字：林工计划 3 月 12 日在深圳与客户确认方案。',
        ),
      ],
      grader: _extractGrader,
    ),
    OnDeviceBenchCase(
      id: 'rewrite-short',
      taskType: OnDeviceBenchTaskType.rewrite,
      tier: OnDeviceBenchInputTier.short,
      turns: [
        OnDeviceBenchTurn.user(
          '把下面句子改写得更简洁，只输出改写后的句子：\n'
          '由于目前设备的温度传感器出现了比较严重的读数漂移现象，我们决定更换该传感器。',
        ),
      ],
      grader: _rewriteGrader,
    ),
    OnDeviceBenchCase(
      id: 'code-short',
      taskType: OnDeviceBenchTaskType.code,
      tier: OnDeviceBenchInputTier.short,
      turns: [OnDeviceBenchTurn.user('用 Kotlin 写一个反转字符串的函数，只输出代码。')],
      grader: _codeGrader,
    ),
    OnDeviceBenchCase(
      id: 'multiTurn-short',
      taskType: OnDeviceBenchTaskType.multiTurn,
      tier: OnDeviceBenchInputTier.short,
      turns: [
        OnDeviceBenchTurn.user('我叫王工，负责深圳地区的设备维护。'),
        OnDeviceBenchTurn.assistant('好的，王工。您负责深圳地区的设备维护工作。'),
        OnDeviceBenchTurn.user('我叫什么名字？我负责哪个城市？'),
      ],
      grader: _multiTurnGrader,
    ),
    OnDeviceBenchCase(
      id: 'qa-long',
      taskType: OnDeviceBenchTaskType.qa,
      tier: OnDeviceBenchInputTier.long,
      turns: [OnDeviceBenchTurn.user('请用一句话介绍骁龙 8 Elite 的 NPU。')],
      grader: _qaGrader,
    ),
    OnDeviceBenchCase(
      id: 'summarize-long',
      taskType: OnDeviceBenchTaskType.summarize,
      tier: OnDeviceBenchInputTier.long,
      turns: [
        OnDeviceBenchTurn.user(
          '请从以下材料中概括要点，不超过 80 字，只输出要点本身：\n$summarizeMaterial',
        ),
      ],
      grader: _summarizeGrader,
    ),
    OnDeviceBenchCase(
      id: 'longDocQa-long',
      taskType: OnDeviceBenchTaskType.longDocQa,
      tier: OnDeviceBenchInputTier.long,
      turns: [
        OnDeviceBenchTurn.user(
          '根据以下材料回答问题，只输出答案：备用电源容量是多少？可维持多久？\n$longDocMaterial',
        ),
      ],
      grader: _longDocQaGrader,
    ),
  ];
}

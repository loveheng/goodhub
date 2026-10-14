/// 流式富文本（P1 前缀块缓存，stream-perf §4）：把「每 delta 一次全文重解析 +
/// 全量重建块 widget」改造为「安全切点增量解析 + 稳定前缀 widget 实例复用 +
/// RepaintBoundary 隔离」，流式期间渲染开销收敛到尾块。
///
/// 组成：
/// - [StreamingBlockCache]：纯 Dart 增量解析引擎（稳定前缀只增不减 + 活跃尾部
///   重解析），导出供单测；
/// - [isSafeCut] / [largestSafeCut]：安全切点扫描（stream-perf §4 跨行上下文
///   禁切规则），导出供等价性 fuzz 单测；
/// - [StreamingRichText]：widget 壳（稳定前缀缓存 + 隔离重绘）。
///
/// 正确性核心（stream-perf §5 等价性门禁）：切点只取行边界且前缀扫描状态干净，
/// 保证 `parse(前缀) + parse(尾部)` 逐块 ≡ `parse(全文)`；跨行块（代码围栏、
/// 数学块 `$$`、引用续行、列表续行、开放表格）一律禁切。parser 仍是共享包
/// `rich_text` 的纯函数实现（零改动、零增量状态机）。
library;

import 'package:flutter/material.dart';
// markdown_subset.dart  export 抽象库 rich_text.dart（AST + RichTextParser），
// 一条 import 即得全量（DIP：解析实现走实现库，AST 类型随 export 可见）。
import 'package:rich_text/markdown_subset.dart';

import '../rich_text_view.dart';

// ---------------------------------------------------------------------------
// 行分类与切点规则（与 MarkdownSubsetParser 块级语义镜像；
// 正则若与 markdown_subset.dart 漂移，由 streaming_rich_text_test.dart 的
// 增量≡全量 fuzz 兜底捕获——SSOT 仍是共享包 parser）
// ---------------------------------------------------------------------------

/// 行分类（切点判定输入；与 parser 的 `_isBlockStart`/责任链语义镜像）。
enum _LineClass {
  /// 空行（块分隔）。
  empty,

  /// 引用行（`^\s*>\s?`）。
  quote,

  /// 列表项（bullet / ordered）。
  listItem,

  /// 裸待办行（`[ ] x` / `[x] x`）——**不是硬块起始**：parser 的
  /// `_isBlockStart` 不含 `_todo`，开放段落会吸收它；仅当主循环轮到该行
  /// （前块已闭合）时才成列表。切点判定按「非块起始」处理。
  todoItem,

  /// 硬块起始（围栏 / 分隔线 / 标题 / 整行图 / 整行媒体链接 / 数学块开头行）。
  blockStart,

  /// 表格起始（行含 `|` 且下一行是分隔线——两行前瞻）。
  tableStart,

  /// 缩进续行（≥2 空格、非块起始、非表格起始、非新列表项）。
  continuation,

  /// 普通文本行。
  other,
}

/// 行元信息：分类 + 是否含 `|`（开放表格按列数吸收后续行的判据）。
class _LineMeta {
  const _LineMeta(this.cls, this.hasPipe);

  final _LineClass cls;
  final bool hasPipe;
}

final _fenceRe = RegExp(r'^```(\w*)\s*$');
final _dividerRe = RegExp(r'^\s*(?:---|\*\*\*|___)\s*$');
final _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
final _quoteRe = RegExp(r'^\s*>\s?');
final _bulletRe = RegExp(r'^\s*[-*+]\s+(.*)$');
final _orderedRe = RegExp(r'^\s*\d+[.)]\s+(.*)$');
final _todoRe = RegExp(r'^\[([ xX])\]\s+(.*)$');
final _imageLineRe = RegExp(r'^!\[([^\]]*)\]\(([^)]*)\)\s*$');
final _linkLineRe = RegExp(r'^\[([^\]]*)\]\(([^)]*)\)\s*$');

/// 引用定义全文探测（multiLine `^` = 逐行锚定，与 parser 首遍收集等价：
/// 定义可被文中任意位置引用，出现即闩锁全量模式、禁一切切点）。
final _refDefAnywhereRe = RegExp(r'^\s*\[([^\]]+)\]:\s*(\S+)', multiLine: true);

const _dollar = r'$$';

/// 数学块开头行判定（与 `_MathBlockSyntax.canParse` 同口径）。
bool _isMathOpener(String line) => line.trim().startsWith(_dollar);

/// 单行是否含「闭合 `$$`」（与 `_MathBlockSyntax._mathHasClosing` 同口径：
/// 裸 `$$` 独立行，或行内 `$$…$$` 且闭合后仅空白）。
bool _mathHasClosing(String line) {
  final t = line.trim();
  if (t == _dollar) return true;
  final first = line.indexOf(_dollar);
  if (first < 0) return false;
  final close = line.indexOf(_dollar, first + 2);
  if (close < 0) return false;
  return line.substring(close + 2).trim().isEmpty;
}

bool _isSeparatorLine(String line) {
  final t = line.trim();
  if (!t.contains('|')) return false;
  final noPipes = t.replaceAll('|', '');
  if (!noPipes.contains('-')) return false;
  return RegExp(r'^[\s:\-]+$').hasMatch(noPipes);
}

/// 行分类（[lines] 供表格两行前瞻）。
_LineMeta _classify(String line, int k, List<(int, String)> lines) {
  final hasPipe = line.contains('|');
  if (line.trim().isEmpty) return _LineMeta(_LineClass.empty, hasPipe);
  // 数学块开头行先于表格裁决（parser 注册表：Math 在 Table 前）——
  // `$$ a | b` 是数学块而非表格行。
  if (_isMathOpener(line)) return _LineMeta(_LineClass.blockStart, hasPipe);
  if (k + 1 < lines.length && hasPipe && _isSeparatorLine(lines[k + 1].$2)) {
    return _LineMeta(_LineClass.tableStart, hasPipe);
  }
  if (_quoteRe.hasMatch(line)) return _LineMeta(_LineClass.quote, hasPipe);
  if (_bulletRe.hasMatch(line) || _orderedRe.hasMatch(line)) {
    return _LineMeta(_LineClass.listItem, hasPipe);
  }
  if (_todoRe.hasMatch(line)) return _LineMeta(_LineClass.todoItem, hasPipe);
  if (_fenceRe.hasMatch(line) ||
      _dividerRe.hasMatch(line) ||
      _headingRe.hasMatch(line) ||
      _imageLineRe.hasMatch(line) ||
      (_linkLineRe.hasMatch(line) &&
          classifyMediaUrl(_linkLineRe.firstMatch(line)!.group(2)!) !=
              MediaSuffix.unknown)) {
    return _LineMeta(_LineClass.blockStart, hasPipe);
  }
  if (line.startsWith('  ')) return _LineMeta(_LineClass.continuation, hasPipe);
  return _LineMeta(_LineClass.other, hasPipe);
}

/// 切点准入（切点后第一行 = [meta]，切点前末行 = [prev]）。
/// 调用方保证：① 前缀扫描状态干净（不在未闭合围栏 / 数学块内）；
/// ② 切点行已完结（`\n` 终止）——末行未完结时其分类可被后续 delta
/// 撤销（`---`→`--- |`、`$$x`→`$$x y`、` `→`  i`），已稳定边界会被回头吞掉；
/// ③ [lookaheadComplete]：表格起始切点的前瞻行（分隔线）是否已完结。
bool _cutAllowed(_LineMeta meta, _LineMeta? prev,
    {required bool lookaheadComplete}) {
  // 开放表格按列数吸收一切含 `|` 的后续行（含被列表/引用/数学正则误中的
  // `- x | y` / `> a | b` / `$$ a | b`）——尾行与前缀末行同含 `|` 一律禁切，
  // 先于分类规则裁决（分类规则会被 listItem/quote 分支提前返回旁路）。
  if (meta.hasPipe && (prev?.hasPipe ?? false)) return false;
  switch (meta.cls) {
    case _LineClass.empty:
      // 空行恒分隔（调用方保证其已完结）。
      return true;
    case _LineClass.quote:
      // 引用续行：前缀末行也是引用行 → 引用块跨行吸收，禁切。
      return prev?.cls != _LineClass.quote;
    case _LineClass.listItem:
      // 列表续行：前缀末行被列表吸收（列表项 / 缩进续行 / 裸待办）→ 禁切。
      // 有序列表吸收无序项，故不区分列表类型。
      return prev?.cls != _LineClass.listItem &&
          prev?.cls != _LineClass.continuation &&
          prev?.cls != _LineClass.todoItem;
    case _LineClass.todoItem:
      // 裸待办不是硬块起始（_isBlockStart 不含 _todo）：开放段落会吸收它，
      // 仅空行/硬块起始之后才有边界——保守一律禁切（尾块持有待办列表，
      // 下一块起始到达时随尾块整体入稳定前缀）。
      return false;
    case _LineClass.blockStart:
      return true;
    case _LineClass.tableStart:
      // 表格起始资格取决于下一行分隔线；该行若未完结，资格可被撤销
      // （`--- | -` → `--- | -x`），故要求前瞻行已完结。
      return lookaheadComplete;
    case _LineClass.continuation:
    case _LineClass.other:
      // 与任何非空前缀末行之间都有段落合并/延续风险，禁切。
      return false;
  }
}

/// 前缀扫描状态（围栏 / 数学块；两个 walk 共用以防语义漂移）。
class _ScanState {
  bool inFence = false;
  bool inMath = false;

  /// 消费一行，推进状态（与 parser 块级语义镜像）：
  /// - 围栏内一切行皆内容，遇 ``` 行闭合；
  /// - 数学块内一切行皆内容，遇含闭合 `$$` 的行闭合；
  /// - 围栏外遇 ``` 行开围栏；数学块开头行开数学块（`$$x$$` 开闭同行除外）。
  void advance(String line) {
    if (inFence) {
      if (_fenceRe.hasMatch(line)) inFence = false;
      return;
    }
    if (_fenceRe.hasMatch(line)) {
      inFence = true;
      return;
    }
    if (inMath) {
      if (_mathHasClosing(line)) inMath = false;
      return;
    }
    if (_isMathOpener(line)) {
      // 裸 `$$` 或行内未闭合 → 跨行等待闭合；`$$x$$` 开闭同行 → 状态干净。
      if (!(line.trim() != _dollar && _mathHasClosing(line))) inMath = true;
    }
  }

  bool get clean => !inFence && !inMath;
}

/// 行切分（保留行起始偏移；`\n` 结尾时末行为空幻尾行——只可作解析输入，
/// 不可作切点：后续 delta 落上去会与前块合并）。
List<(int, String)> _splitLines(String text) {
  final out = <(int, String)>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      out.add((start, text.substring(start, i)));
      start = i + 1;
    }
  }
  out.add((start, text.substring(start)));
  return out;
}

/// 从 [from]（行边界）起以干净状态扫描到文末，返回最大安全切点偏移（无则 null）。
///
/// 前置不变量：[from] 必须是干净状态的行边界（[StreamingBlockCache] 只把
/// 稳定长度设在安全切点上，天然满足）。跨行上下文禁切规则见 [_cutAllowed]；
/// 引用定义闩锁与 [isSafeCut] 同口径（全文探测），两函数语义一致。
int? largestSafeCut(String text, int from) {
  if (_refDefAnywhereRe.hasMatch(text)) return null;
  final base = from;
  final region = text.substring(base);
  final lines = _splitLines(region);
  final n = lines.length;
  final state = _ScanState();
  int? cut;
  _LineMeta? prev;
  for (var k = 0; k < n; k++) {
    final content = lines[k].$2;
    final meta = _classify(content, k, lines);
    // 候选切点 = 下一行起始偏移。准入门槛：
    // ① k ≥ 1（首行是 from 自身，不候选）；
    // ② k < n-1——切点行必须已完结（`\n` 终止）。末行未完结时其分类可被
    //    后续 delta 撤销（`---`→`--- |`、` `→`  i`、`$$x`→`$$x y`），
    //    把已稳定的边界回头吞掉；幻尾行（k = n-1 且为空）被此条泛化排除。
    // ③ 前缀扫描状态干净（不在未闭合围栏 / 数学块内）。
    if (k >= 1 && k < n - 1 && state.clean) {
      if (_cutAllowed(meta, prev, lookaheadComplete: k + 1 < n - 1)) {
        cut = base + lines[k].$1;
      }
    }
    // 状态推进在切点判定之后：围栏/数学块归属前缀扫描状态。
    state.advance(content);
    prev = meta;
  }
  return cut;
}

/// 单切点安全性判定（自包含，从文档头扫描；导出供单测，stream-perf §5）。
///
/// [cut] 必须为行边界偏移；返回 true 时保证
/// `parse(text[0..cut)) + parse(text[cut..))` 逐块 ≡ `parse(text)`。
bool isSafeCut(String text, int cut) {
  if (cut <= 0 || cut >= text.length) return false;
  if (_refDefAnywhereRe.hasMatch(text)) return false;
  final lines = _splitLines(text);
  final j = lines.indexWhere((l) => l.$1 == cut);
  if (j <= 0) return false; // 非行边界 / 文档头
  // 切点行必须已完结（k < n-1）：末行未完结时分类可被 delta 撤销；
  // 幻尾行（文本以 \n 结尾的末空行）被此条一并排除。
  if (j >= lines.length - 1) return false;
  final state = _ScanState();
  for (var k = 0; k < j; k++) {
    state.advance(lines[k].$2);
  }
  if (!state.clean) return false;
  return _cutAllowed(
    _classify(lines[j].$2, j, lines),
    _classify(lines[j - 1].$2, j - 1, lines),
    lookaheadComplete: j + 1 < lines.length - 1,
  );
}

// ---------------------------------------------------------------------------
// 增量解析引擎（纯 Dart，导出供单测）
// ---------------------------------------------------------------------------

/// 流式块缓存（P1 核心，stream-perf §4）：稳定前缀（AST 只增不减）+ 活跃尾部
/// （每次喂入重解析）。不变量：`stableBlocks + tailBlocks` ≡ 全文 `parse`。
class StreamingBlockCache {
  StreamingBlockCache({RichTextParser? parser})
      : _parser = parser ?? const MarkdownSubsetParser();

  final RichTextParser _parser;

  List<RichBlock> _stableBlocks = const [];
  List<RichBlock> _tailBlocks = const [];
  int _stableLen = 0;
  bool _hasRefDefs = false;

  /// 稳定前缀块（widget 侧缓存其渲染产物）。
  List<RichBlock> get stableBlocks => _stableBlocks;

  /// 活跃尾部块（每次喂入重算）。
  List<RichBlock> get tailBlocks => _tailBlocks;

  /// 稳定前缀文本长度（归一化坐标；widget 侧据此失效渲染缓存）。
  int get stableLen => _stableLen;

  /// 当前完整块视图（稳定前缀 + 活跃尾部）。
  List<RichBlock> get blocks => [..._stableBlocks, ..._tailBlocks];

  /// 喂入当前全量文本（流式追加语义；只增长，收缩时防御性全量重置）。
  void ingest(String raw) {
    // 与 parser 内部同口径的换行归一化（切点坐标在归一化文本上维护）。
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 不变量防御：稳定长度必须落在行边界且不越界（TrackText 只增不减，
    // 此处仅兜底异常输入）。
    if (text.length < _stableLen ||
        (_stableLen > 0 && text[_stableLen - 1] != '\n')) {
      _reset();
    }
    if (!_hasRefDefs && _refDefAnywhereRe.hasMatch(text)) {
      // 引用定义闩锁：定义可被任意位置引用，禁一切切点，退化全量 parse。
      _hasRefDefs = true;
      _reset();
    }
    if (!_hasRefDefs) {
      final cut = largestSafeCut(text, _stableLen);
      if (cut != null && cut > _stableLen) {
        _stableBlocks = [
          ..._stableBlocks,
          ..._parser.parse(text.substring(_stableLen, cut)),
        ];
        _stableLen = cut;
      }
    }
    _tailBlocks = text.length == _stableLen
        ? const []
        : _parser.parse(text.substring(_stableLen));
  }

  void _reset() {
    _stableBlocks = const [];
    _stableLen = 0;
  }
}

// ---------------------------------------------------------------------------
// widget 壳（稳定前缀缓存 + 隔离重绘）
// ---------------------------------------------------------------------------

/// 流式富文本渲染（P1，stream-perf §4）：
/// - 稳定前缀包 [RepaintBoundary] + 缓存 widget 实例——跨 build 同一实例，
///   Element 复用跳过 layout；RepaintBoundary 独立图层跳过尾块更新时的
///   前缀重绘（Flutter 侧对应 Web 的 `contain: content`）；
/// - 尾块每次 build 经 [RichTextView] 重建（范围 = 当前流式块，代价有界）；
/// - 主题切换无需失效缓存：RichTextView 的 Element 自行依赖 Theme 注入，
///   InheritedWidget 变更会标记其重建，tokens 自然刷新。
class StreamingRichText extends StatefulWidget {
  const StreamingRichText({super.key, required this.text});

  /// 当前全量文本快照（页面每次刷盘写入新 String）。
  final String text;

  @override
  State<StreamingRichText> createState() => _StreamingRichTextState();
}

class _StreamingRichTextState extends State<StreamingRichText> {
  final _cache = StreamingBlockCache();

  /// 稳定前缀渲染缓存（稳定长度增长时失效）。
  Widget? _stableView;

  @override
  void initState() {
    super.initState();
    _cache.ingest(widget.text);
  }

  @override
  void didUpdateWidget(covariant StreamingRichText old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    final before = _cache.stableLen;
    _cache.ingest(widget.text);
    if (_cache.stableLen != before) _stableView = null;
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (_cache.stableBlocks.isNotEmpty)
        RepaintBoundary(
          child: _stableView ??= RichTextView(blocks: _cache.stableBlocks),
        ),
      if (_cache.tailBlocks.isNotEmpty)
        RichTextView(blocks: _cache.tailBlocks),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

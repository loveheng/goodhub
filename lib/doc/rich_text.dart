/// 富文本模型与解析（Markdown 子集 → 块树）。
///
/// SSOT：docs/design/content-pipeline.md §3 / §5，docs/design/ui-spec.md §2.2。
///
/// 为什么要自建而不用 `flutter_markdown_plus`：
/// 1. **待办勾选在渲染器架构下无法实现**——渲染器输出不可交互文本流，而
///    `ui-spec` §7 要求 `human_md` 中 `[ ]` 可勾选、状态写 `todo_state_json`
/// 2. 该包是原包归档停更后的社区分叉
/// 3. 文档感全靠排版参数，受渲染器内部结构限制
///
/// 降级铁律：**宁可样式平，不可吞内容**——不认识的块一律降级为段落，
/// 绝不丢弃任何字符。
///
/// ---
/// **goodhub 随迁注记（2026-10-11，M4-T3 / D12）**：本文件自 goodshare 仓
/// `lib/doc/rich_text.dart` 原样随迁（零依赖纯解析）。双仓共存、各自演进，
/// 分叉风险已知——出现第二处跨仓复用再评估抽共享包（solution-admission）。
/// goodshare 侧 SSOT（content-pipeline / ui-spec）仅约束 goodshare 本体；
/// goodhub 消费面 = 聊天阅读轨只读渲染（`lib/ui/rich_text_view.dart`，
/// D12 拍板：goodshare 自写方案随迁，不引 flutter_markdown 系三方包）。

library;

// ---------- 行内 ----------

/// 行内节点。
sealed class InlineNode {
  const InlineNode();
}

/// 纯文本。
class InlineText extends InlineNode {
  const InlineText(this.text);

  final String text;
}

/// 粗体（`**` 或 `__`）。
class InlineStrong extends InlineNode {
  const InlineStrong(this.children);

  final List<InlineNode> children;
}

/// 斜体（`*` 或 `_`）。
class InlineEm extends InlineNode {
  const InlineEm(this.children);

  final List<InlineNode> children;
}

/// 下划线（`<u>` 标签）。
///
/// Markdown 标准无下划线语法——`<u>` 是 md 生态事实标准（HTML 内嵌），桌面端
/// 多数渲染器兼容；解析/渲染/序列化三出口同文件同源（block-format-input.md §2）。
class InlineUnderline extends InlineNode {
  const InlineUnderline(this.children);

  final List<InlineNode> children;
}

/// 行内代码。
class InlineCode extends InlineNode {
  const InlineCode(this.code);

  final String code;
}

/// 链接（`[文字](url)`）。**默认不可点击**（不引 `url_launcher`），
/// 仅以链接样式呈现。
///
/// [autolink] = true 表示由自动链接（裸 `url` / `www.` / `mailto:`，见 §3.6 ⑤）
/// 识别而来：label 即 url，序列化回裸 url（不包 `<>` / 不包 `[]()`）。
class InlineLink extends InlineNode {
  const InlineLink({required this.label, required this.url, this.autolink = false});

  final String label;
  final String url;
  final bool autolink;
}

/// 删除线（~~text~~，GFM 官方扩展，§3.6 收编）。
class InlineStrikethrough extends InlineNode {
  const InlineStrikethrough(this.children);

  final List<InlineNode> children;
}

/// 高亮（==text==，Pandoc/Obsidian 事实标准，§3.6 收编）。
class InlineHighlight extends InlineNode {
  const InlineHighlight(this.children);

  final List<InlineNode> children;
}

// ---------- 块级 ----------

/// 块节点。
sealed class RichBlock {
  const RichBlock();
}

/// 标题（level 1-6）。
class HeadingBlock extends RichBlock {
  const HeadingBlock({required this.level, required this.inline});

  final int level;
  final List<InlineNode> inline;
}

/// 段落。
class ParagraphBlock extends RichBlock {
  const ParagraphBlock(this.inline);

  final List<InlineNode> inline;
}

/// 表格列对齐（GFM `:---` / `:--:` / `---:`）。
enum TableAlign { left, center, right }

/// 表格块（GFM 官方扩展，§3.6 ④）。单元格以**纯文本字面**存储（避免单元格内
/// `|` 转义复杂度，列为后续项），渲染层对单元格做行内解析（§3.5 / §5.4
/// 「表格内行内格式仍解析」），故往返幂等且 UI 无残壳。
class TableBlock extends RichBlock {
  const TableBlock({required this.header, required this.rows, this.align});

  final List<String> header;
  final List<List<String>> rows;
  final List<TableAlign>? align;
}

/// 引用块（内部递归解析，支持引用内多段）。
class QuoteBlock extends RichBlock {
  const QuoteBlock(this.children);

  final List<RichBlock> children;
}

/// 列表项。`done` 非 null 表示这是待办项（可勾选）。
///
/// [lines] 首行为 `- `/`1. `/`- [ ] ` 标记后的内容；后续元素为「续行」
/// （markdown 中以 ≥2 空格缩进表示，解析层归入同一项）。单行项仅一个元素。
/// [inline] 为 [lines] 首行的兼容 getter，单行调用可继续用。
class ListItem {
  const ListItem(this.lines, {this.done});

  final List<List<InlineNode>> lines;

  /// 首行内容（兼容旧单行调用；多行项请直接用 [lines]）。
  List<InlineNode> get inline =>
      lines.isEmpty ? const [InlineText('')] : lines.first;

  /// true = 已完成 `[x]`，false = 未完成 `[ ]`，null = 普通列表项。
  final bool? done;
}

/// 列表（有序 / 无序）。
class ListBlock extends RichBlock {
  const ListBlock({required this.ordered, required this.items});

  final bool ordered;
  final List<ListItem> items;
}

/// 代码块（围栏 ```）。
class CodeBlock extends RichBlock {
  const CodeBlock({required this.code, this.language});

  final String code;
  final String? language;
}

/// 分隔线。
class DividerBlock extends RichBlock {
  const DividerBlock();
}

/// 行内图片块（整行 `![alt](url)`，SSOT：docs/design/rich-text-media.md §2）。
class ImageBlock extends RichBlock {
  const ImageBlock({required this.url, this.alt = ''});

  final String url;

  /// 图片说明（用户/AI 原话，规则层禁加类型前缀——往返幂等）。
  final String alt;
}

/// 行内音频块（整行 `[label](url)` 且 url 后缀命中音频白名单）。
class AudioBlock extends RichBlock {
  const AudioBlock({required this.url, this.label = ''});

  final String url;
  final String label;
}

/// 行内视频块（整行 `[label](url)` 且 url 后缀命中视频白名单）。
class VideoBlock extends RichBlock {
  const VideoBlock({required this.url, this.label = ''});

  final String url;
  final String label;
}

// ---------- 媒体 url 后缀分类 ----------

/// 媒体 url 后缀归类（rich-text-media.md §2 白名单两档）。
enum MediaSuffix {
  /// 音频，可直接内嵌播放。
  audioPlayable,

  /// 音频但平台兼容性存疑（如 .amr）：parse 照常归 AudioBlock（AST 不携带
  /// 能力信息），呈现层降级为文件卡不进播放器。
  audioDegrade,

  /// 视频。
  video,

  /// 非媒体或未识别。
  unknown,
}

const Set<String> _audioPlayableExt = {'.mp3', '.m4a', '.aac', '.wav', '.opus'};
const Set<String> _audioDegradeExt = {'.amr'};
const Set<String> _videoExt = {'.mp4', '.mov', '.webm', '.m3u8'};

/// url → 后缀归类。取 `Uri.parse(url).path`（天然剥离 query 与 fragment）、
/// toLowerCase 后与白名单比对；parse 与呈现层共用此单一事实源。
MediaSuffix classifyMediaUrl(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return MediaSuffix.unknown;
  final ext = path.substring(dot).toLowerCase();
  if (_audioPlayableExt.contains(ext)) return MediaSuffix.audioPlayable;
  if (_audioDegradeExt.contains(ext)) return MediaSuffix.audioDegrade;
  if (_videoExt.contains(ext)) return MediaSuffix.video;
  return MediaSuffix.unknown;
}

/// AI 回写防冲刷护城河（2026-09-30 拍板叮嘱②，rich-text-media.md §7）：
/// 对比原 md 与 AI 产出 md 的**行内媒体块 url 集合**，返回原文有而产出丢失的 url。
/// 非空 = AI 润色/重构自作主张删掉了用户媒体资产，动作层必须拒绝整替（保留原文）。
/// 只对 apply_ai_result 管线回写生效；UI/MCP 的 update 走块编辑器，用户删媒体是合法操作。
Set<String> lostMediaUrls(String originalMd, String incomingMd) {
  Set<String> mediaUrlsOf(String md) => {
    for (final b in MarkdownSubsetParser().parse(md))
      ...switch (b) {
        ImageBlock(:final url) => {url},
        AudioBlock(:final url) => {url},
        VideoBlock(:final url) => {url},
        _ => <String>{},
      },
  };
  final original = mediaUrlsOf(originalMd);
  if (original.isEmpty) return const {};
  return original.difference(mediaUrlsOf(incomingMd));
}

/// AI 写入归一结果（rich-text-gfm.md §2 层2 语义映射 + R1 note 载体）。
///
/// [markdown] = 归一后（子集内、无残壳）的 md；[notes] = 本次发生的降级映射
/// 说明，供命令返回体/MCP 响应带 R1 note 回传 AI 可感知（映射即降级须告知）。
class AiNormalizeResult {
  const AiNormalizeResult(this.markdown, this.notes);

  final String markdown;
  final List<String> notes;
}

/// 检测子集外、会被解析器降级为段落的 GFM 语法（仅取低误报信号）：
/// 块级数学式 `$$…$$`、行内 HTML 标签 `<…>`（跳过敏感代码围栏）。
/// 命中即说明有内容会被「降级」而非「丢字」——用于 R1 告知 AI。
bool _hasUnsupportedGfm(String markdown) {
  final lines = markdown.split('\n');
  var inFence = false;
  for (final line in lines) {
    if (line.trim().startsWith('```') || line.trim().startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (line.contains(RegExp(r'\$\$'))) return true;
    // 排除 GFM 角括号自动链接 <https://…>/<mailto:…>，避免误报为不支持 HTML
    if (RegExp(r'<(?!https?://|mailto:)[a-zA-Z/!][^>\n]*>').hasMatch(line)) {
      return true;
    }
  }
  return false;
}

/// AI 写入归一层（rich-text-gfm.md §2 层2，命令入口唯一收口）：对**全集外**语法
/// 做语义映射（找最接近的子集形式降级，不做「剥成纯文本」），并集外降级进
/// [AiNormalizeResult.notes] 供 R1 告知；**全集内**（表格/高亮/删除线/自动链接/
/// R3 引用链接，`MarkdownSubsetParser` 已零映射零残壳）原样透传，不改动一字。
///
/// 当前全集外映射：
/// 1. 脚注 `[^id]` + 定义 `[^id]: text`（含后续缩进续行）→ 括号注 `（text）`，
///    定义行（含续行）作 meta 剥离；R1 note「脚注已转为括号注」。
/// 2. 子集外结构（数学式/HTML 标签等）检测命中 → R1 note 告知「已降级为段落」。
/// 未定义脚注 `[^id]` 留字面 + note「存在未定义脚注标记，已保留原样」
/// （禁止静默丢格式）。其余未知结构由解析器降级为段落（不丢内容），不在本层二次处理。
AiNormalizeResult normalizeAiMarkdown(String markdown) {
  final notes = <String>[];

  // 脚注定义收集（行首 `^\[\^id\]: text`，含后续缩进续行）
  final defRe = RegExp(r'^\s*\[\^([^\]]+)\]:\s*(.*)$');
  final defs = <String, String>{};
  final removed = <int>{};
  final lines = markdown.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = defRe.firstMatch(lines[i]);
    if (m == null) continue;
    final id = m.group(1)!.toLowerCase();
    final buf = [m.group(2)!.trim()];
    removed.add(i);
    // 续行：后续以空白缩进的行并入同一脚注正文（GFM 脚注续行约定）
    var j = i + 1;
    while (j < lines.length && RegExp(r'^[ \t]+\S').hasMatch(lines[j])) {
      buf.add(lines[j].trim());
      removed.add(j);
      j++;
    }
    defs[id] = buf.join(' ');
    i = j - 1; // 跳过已消费续行
  }

  // 剥离定义行 + 续行；行尾换行保留为空行，解析器忽略空行，不丢相邻内容
  final outLines = <String>[
    for (var i = 0; i < lines.length; i++)
      if (!removed.contains(i)) lines[i],
  ];
  var out = outLines.join('\n');

  // 内联 `[^id]` → `（text）`；未定义则留字面并记 orphan（禁止静默丢格式）
  var orphan = false;
  out = out.replaceAllMapped(RegExp(r'\[\^([^\]]+)\]'), (m) {
    final text = defs[m.group(1)!.toLowerCase()];
    if (text == null) {
      orphan = true;
      return m.group(0)!;
    }
    return '（$text）';
  });

  // 子集外结构降级告知（R1）
  if (_hasUnsupportedGfm(out)) {
    notes.add('检测到未支持的 GFM 语法（如数学式、HTML 标签），已降级为普通段落；'
        '建议改用纯文本、表格或列表等已支持格式');
  }

  if (defs.isNotEmpty) notes.add('脚注已转为括号注');
  if (orphan) notes.add('存在未定义脚注标记，已保留原样');
  return AiNormalizeResult(out, notes);
}

/// 行内节点 → 纯文本（待办回调取文本、复制、检索预览用）。
///
/// 只取「人读到的字」，不含标记符号。
String inlineToPlain(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => text,
      InlineStrong(:final children) => inlineToPlain(children),
      InlineEm(:final children) => inlineToPlain(children),
      InlineUnderline(:final children) => inlineToPlain(children),
      InlineCode(:final code) => code,
      InlineLink(:final label) => label,
      InlineStrikethrough(:final children) => inlineToPlain(children),
      InlineHighlight(:final children) => inlineToPlain(children),
    }).join();

/// 扫描 markdown 中的**待办行纯文本**（2026-10-05 待办勾选批次）。
///
/// 与渲染同源：ListBlock 中 `done != null` 的项（含列表式与裸 `[ ]` 行——
/// 解析层把裸待办归入单项列表）。返回 [inlineToPlain] 同款纯文本并 trim，
/// 即 `TodoMark.hashOf` 的输入口径——渲染侧与写侧 GC 共用本函数，保证
/// 「所见文本 = 所算 hash」。引用块内待办一并扫出（渲染层引用块递归同构）。
List<String> scanTodoTexts(String markdown) {
  void walk(List<RichBlock> bs, List<String> out) {
    for (final b in bs) {
      switch (b) {
        case ListBlock(:final items):
          for (final it in items) {
            if (it.done != null) {
              out.add(it.lines.map(inlineToPlain).join('\n').trim());
            }
          }
        case QuoteBlock(:final children):
          walk(children, out);
        default:
          break;
      }
    }
  }

  final out = <String>[];
  walk(const MarkdownSubsetParser().parse(markdown), out);
  return out;
}

/// 块 → 纯文本（预览 / 检索用）。
String blockToPlain(RichBlock block) => switch (block) {
      HeadingBlock(:final inline) => inlineToPlain(inline),
      ParagraphBlock(:final inline) => inlineToPlain(inline),
      QuoteBlock(:final children) => children.map(blockToPlain).join('\n'),
      ListBlock(:final items) =>
        items.map((i) => i.lines.map(inlineToPlain).join('\n')).join('\n'),
      CodeBlock(:final code) => code,
      DividerBlock() => '',
      // 媒体块降级（三出口之 blockToPlain，rich-text-media.md §2）
      ImageBlock(:final alt) => alt.isEmpty ? '[图片]' : '[图片: $alt]',
      AudioBlock(:final label) => label.isEmpty ? '[音频]' : '[音频: $label]',
      VideoBlock(:final label) => label.isEmpty ? '[视频]' : '[视频: $label]',
      TableBlock(:final header, :final rows) =>
        [...header, for (final r in rows) ...r].join(' '),
    };

/// Markdown 子集 → 纯文本（整篇剥壳，blockToPlain 的字符串出口）。
///
/// 列表卡片/工作区封面等「无富文本渲染能力」的预览位统一走此函数，
/// 保证 `# 标题`、`**粗体**`、`![图片](…)` 等标记不出现在纯文本场景
/// （渲染出口在 ContentBody/RichTextView，不受影响）。
String markdownToPlain(String markdown) =>
    MarkdownSubsetParser().parse(markdown).map(blockToPlain).join('\n\n');

/// 行内文本 → 纯文本（标题剥壳出口）：剥 `**`/`*`/`<u>`/`==` 等行内标记，
/// 但**不**剥行首 `#` 级联（见 [titleToPlain] 的分级口径）。
String inlineToPlainText(String source) =>
    inlineToPlain(const MarkdownSubsetParser().parseInline(source));

/// 标题文本 → 纯文本（顶栏标题 / 列表预览标题专用）：在行内剥壳之上**额外**
/// 剥一层行首 `#` 前缀——速记一级标题行既会渲染成正文 Heading（ContentBody），
/// 也会被 noteTitleOf 派生成条目标题；标题位是纯文本场景，任何口径都不得
/// 出现 `#` 残壳（用户拍板：纯文本一律无 md 标记）。
String titleToPlain(String source) {
  final plain = inlineToPlainText(source);
  final m = RegExp(r'^#{1,6}\s+').firstMatch(plain);
  return m == null ? plain : plain.substring(m.end);
}

// ---------- 行内样式 run（block-format-input.md §4 样式化编辑层地基） ----------

/// 行内样式种类（编辑态样式化层用；渲染即 switch 出对应 TextStyle 增量）。
enum InlineMark { bold, italic, code, underline, link, strikethrough, highlight }

/// 一个样式 run：**纯文本坐标** [start, end)（标记字符已剥除）。
/// 嵌套（如粗体含于下划线）以重叠 run 表达——渲染侧按字符合成样式。
class InlineRun {
  const InlineRun(this.start, this.end, this.mark, {this.url});

  final int start;
  final int end;
  final InlineMark mark;

  /// 仅 link run 携带：plain 只含 label，url 由 run 载荷保全（数据无损防线）。
  final String? url;
}

/// 源 md 行内文本的样式化投影：[plain]（标记剥除后的纯文本）+ [runs]。
///
/// **同源护栏**：[plain] 必须与 `inlineToPlain(parseInline(source))` 逐字符
/// 一致（单测锁定）——样式化编辑层的输入层与渲染层都以 [plain] 为唯一文本，
/// 两层零位移（§4.2 对位风险的第一道防线）。分支顺序/转义/不闭合降级语义
/// 必须与 [MarkdownSubsetParser.parseInline] 镜像，改一处必改另一处。
InlineSpans inlineSpansOf(String source) {
  final buf = StringBuffer();
  final runs = <InlineRun>[];
  final active = <InlineMark>{};

  void emit(String plain, {String? url}) {
    if (plain.isEmpty) return;
    final start = buf.length;
    buf.write(plain);
    for (final m in active) {
      runs.add(InlineRun(start, buf.length, m, url: url));
    }
  }

  // 分支顺序与分组号与 parseInline 严格镜像（lesson：插分支必同步分组号）
  void walk(String text) {
    final codeSpans = MarkdownSubsetParser._extractCode(text);
    final events = <_InlineEvent>[];
    for (final c in codeSpans) {
      events.add(_InlineEvent(c.$1, c.$2, code: c.$3));
    }
    for (final m in MarkdownSubsetParser._inlinePattern.allMatches(text)) {
      if (codeSpans.any((c) => m.start < c.$2 && c.$1 < m.end)) continue;
      events.add(_InlineEvent(m.start, m.end, match: m));
    }
    events.sort((a, b) => a.start.compareTo(b.start));

    var pos = 0;
    for (final ev in events) {
      if (ev.start > pos) emit(text.substring(pos, ev.start));
      if (ev.code != null) {
        active.add(InlineMark.code);
        emit(ev.code!);
        active.remove(InlineMark.code);
      } else {
        final m = ev.match!;
        if (m.group(1) != null) {
          emit(m.group(1)!);
        } else if (m.group(2) != null) {
          active.add(InlineMark.link);
          emit(m.group(2)!, url: m.group(2)!);
          active.remove(InlineMark.link);
        } else if (m.group(4) != null) {
          active.add(InlineMark.bold);
          active.add(InlineMark.italic);
          walk(m.group(4)!);
          active.remove(InlineMark.italic);
          active.remove(InlineMark.bold);
        } else if (m.group(6) != null) {
          active.add(InlineMark.bold);
          walk(m.group(6)!);
          active.remove(InlineMark.bold);
        } else if (m.group(8) != null) {
          active.add(InlineMark.italic);
          walk(m.group(8)!);
          active.remove(InlineMark.italic);
        } else if (m.group(9) != null) {
          active.add(InlineMark.underline);
          walk(m.group(9)!);
          active.remove(InlineMark.underline);
        } else if (m.group(10) != null) {
          active.add(InlineMark.strikethrough);
          walk(m.group(10)!);
          active.remove(InlineMark.strikethrough);
        } else if (m.group(11) != null) {
          active.add(InlineMark.highlight);
          walk(m.group(11)!);
          active.remove(InlineMark.highlight);
        } else if (m.group(12) != null) {
          active.add(InlineMark.link);
          emit(MarkdownSubsetParser._unescape(m.group(12)!),
              url: m.group(13) ?? '');
          active.remove(InlineMark.link);
        }
      }
      pos = ev.end;
    }
    if (pos < text.length) emit(text.substring(pos));
  }

  walk(source);
  return InlineSpans(plain: buf.toString(), runs: runs);
}

/// [inlineSpansOf] 的返回：纯文本 + 纯文本坐标的样式 run 列表。
class InlineSpans {
  const InlineSpans({required this.plain, required this.runs});

  final String plain;
  final List<InlineRun> runs;
}

/// 行内解析事件（[MarkdownSubsetParser.parseInline] / [inlineSpansOf] 共用）：
/// 要么是一段行内码，要么是一处正则命中。
class _InlineEvent {
  const _InlineEvent(this.start, this.end, {this.code, this.match});
  final int start;
  final int end;
  final String? code;
  final RegExpMatch? match;
}

/// 行级档位 run（速记所见即所得的行标题，2026-10-03）：**纯文本坐标**
/// [start, end)，恒与实际整行对齐（宿主侧 snap；详情页标题是块属性不用它）。
class SpanLevelRun {
  const SpanLevelRun(this.start, this.end, this.level);

  final int start;
  final int end;

  /// 0 正文 / 1 一级标题 / 2 二级标题（0 不参与渲染，序列化侧消费）。
  final int level;
}

/// 列表种类（速记所见即所得的「行列表」维度，2026-10-06 拍板：粘贴/导入 md
/// 列表 → 无标记列表/待办）：bullet = 无序圆点（`- ` / `* `），
/// todo = 待办（`- [ ]` / `- [x]`），ordered = 有序项（`N. ` / `N) `，序号
/// **不由 run 存储**——始终由所处连续有序组实时推算，保证增删项后自动重排，
/// 与详情页解析器「每个 ListBlock 从 1 重排」同口径）。
/// 与行级标题同源——**行属性**，整行表达，恒与实际整行对齐（宿主侧 snap）。
enum SpanListKind { bullet, todo, ordered }

/// 行列表 run：**纯文本坐标** [start, end)，覆盖一整行（不含行尾 `\n`）；
/// 多行列表项时 [end] 会吞入后续「≥2 空格缩进」的续行作几何延伸——仍只算
/// **一个**列表项（凹槽只按 [start] 所在首行绘制一次，续行留白不重复出标记）。
/// 标题与列表互斥（一行只认一种前缀，标题优先）。
class SpanListRun {
  const SpanListRun(this.start, this.end, this.kind, {this.done = false});

  final int start;
  final int end;
  final SpanListKind kind;

  /// 待办勾选态（仅 [SpanListKind.todo] 有意义）；渲染侧消费，不改正文。
  final bool done;
}

/// 文本变更区间（旧坐标）：最长公共前/后缀夹出「删旧 + 插新」窗口。
/// 纯函数，供 [adjustRuns] 与会话层随动使用。
(int, int) spanChangeRange(String oldText, String newText) {
  var p = 0;
  while (p < oldText.length && p < newText.length && oldText[p] == newText[p]) {
    p++;
  }
  var sOld = oldText.length;
  var sNew = newText.length;
  while (sOld > p && sNew > p && oldText[sOld - 1] == newText[sNew - 1]) {
    sOld--;
    sNew--;
  }
  return (p, sOld);
}

/// 文字变更时 run 随动（纯函数）：删除区裁剪、其后位移、run 内插入延展。
/// 重叠模型下不做合并——渲染按字符合成，语义即正确。
List<InlineRun> adjustRuns(
  List<InlineRun> runs,
  int start,
  int oldEnd,
  int insertLen,
) {
  final delta = insertLen - (oldEnd - start);
  final out = <InlineRun>[];
  for (final r in runs) {
    var s = r.start;
    var e = r.end;
    if (e <= start) {
      // 完全在变更区前：不动（含「插入点=run 末尾」——边界不延续，
      // 新文字是否入格式由激活态决定，先选后打拍板）
    } else if (s >= oldEnd) {
      // 完全在变更区后（含「插入点=run 起点」）：整体位移
      s += delta;
      e += delta;
    } else if (start == oldEnd) {
      // 纯插入且严格位于 run 内部：延展
      if (s < start) e += insertLen;
    } else {
      // 删除/替换：横跨（或触及）替换窗的 run 涵盖插入段（字级替换不打断
      // 样式连续性），尾部在窗内的 run 裁掉窗内部分；完全在窗内的 run 删空。
      final ns = s < start ? s : start;
      final ne = e >= oldEnd
          ? start + insertLen + (e - oldEnd)
          : ns + (e - start > 0 ? 0 : 0) + (e - start).clamp(0, start - s);
      s = ns;
      e = ne;
      if (e <= s) continue; // run 被删空
    }
    out.add(InlineRun(s, e, r.mark, url: r.url));
  }
  return out;
}

/// 选区套格式（编辑态样式化层）：在 [start, end) 上切换 [mark]。
/// 重叠模型：先按边界切分跨 start/end 的 mark run，整段已覆盖则摘掉、否则清掉
/// 重叠部分后整段盖上——纯函数，供 [ComposerDoc.applyMarkToSelection] 复用。
List<InlineRun> toggleInlineMarkRuns(
  List<InlineRun> runs,
  InlineMark mark,
  int start,
  int end,
) {
  if (end <= start) return runs;
  // 1. 边界切分：把跨 start/end 的 mark run 断开，避免局部覆盖残留
  final split = <InlineRun>[];
  for (final r in runs) {
    if (r.mark != mark) {
      split.add(r);
      continue;
    }
    if (r.start < start && start < r.end) {
      split.add(InlineRun(r.start, start, mark, url: r.url));
      split.add(InlineRun(start, r.end, mark, url: r.url));
      continue;
    }
    if (r.start < end && end < r.end) {
      split.add(InlineRun(r.start, end, mark, url: r.url));
      split.add(InlineRun(end, r.end, mark, url: r.url));
      continue;
    }
    split.add(r);
  }
  // 2. 区间内 mark 覆盖度判定
  final intervals = <(int, int)>[];
  for (final r in split) {
    if (r.mark != mark) continue;
    final s = r.start.clamp(start, end);
    final e = r.end.clamp(start, end);
    if (e > s) intervals.add((s, e));
  }
  intervals.sort((a, b) => a.$1.compareTo(b.$1));
  var covered = start;
  for (final (s, e) in intervals) {
    if (s > covered) break;
    covered = e > covered ? e : covered;
  }
  final fullyCovered = covered >= end;
  // 3. 清掉区间内 mark run（无论开/关都先清，避免重叠残留）
  final cleared = split
      .where((r) => !(r.mark == mark && r.end > start && r.start < end))
      .toList();
  if (fullyCovered) return cleared;
  cleared.add(InlineRun(start, end, mark));
  return cleared;
}

/// runs + plain → 行内节点树（slice-4 序列化回写与块重建的唯一出口）。
/// 重叠 run 按字符合成标记集合，相邻同集合（含同 link url）段合并；
/// 嵌套优先级固定为枚举顺序（bold > italic > code > underline > link）。
/// link run 的 url 从载荷还原——编辑链接文字不丢 url（数据无损防线）。
List<InlineNode> inlineNodesOf(String plain, List<InlineRun> runs) {
  final sets = List<Set<InlineMark>>.generate(
    plain.length,
    (_) => {},
    growable: false,
  );
  final urls = List<String?>.generate(plain.length, (_) => null, growable: false);
  for (final r in runs) {
    for (var i = r.start; i < r.end && i < plain.length; i++) {
      sets[i].add(r.mark);
      if (r.mark == InlineMark.link) urls[i] = r.url;
    }
  }
  InlineNode styled(String text, Set<InlineMark> marks, String? url) {
    InlineNode n = InlineText(text);
    for (final m in InlineMark.values) {
      if (!marks.contains(m)) continue;
      n = switch (m) {
        InlineMark.bold => InlineStrong([n]),
        InlineMark.italic => InlineEm([n]),
        InlineMark.code => InlineCode(text),
        InlineMark.underline => InlineUnderline([n]),
        InlineMark.link => InlineLink(label: text, url: url ?? ''),
        InlineMark.strikethrough => InlineStrikethrough([n]),
        InlineMark.highlight => InlineHighlight([n]),
      };
    }
    return n;
  }

  final out = <InlineNode>[];
  var i = 0;
  while (i < plain.length) {
    var j = i + 1;
    while (j < plain.length &&
        sets[j].length == sets[i].length &&
        sets[j].containsAll(sets[i]) &&
        urls[j] == urls[i]) {
      j++;
    }
    final seg = plain.substring(i, j);
    out.add(styled(seg, sets[i], urls[i]));
    i = j;
  }
  return out;
}

// ---------- 序列化 ----------/// 行内纯文本需转义的字符：`\` 本身与子集语法标记（`*` `_` `[` `` ` ``）。
final RegExp _escapeInlineRe = RegExp(r'[\\*_[`]');

String _escapeText(String s) =>
    s.replaceAllMapped(_escapeInlineRe, (m) => '\\${m[0]}');

/// 行内节点 → Markdown 子集串。与 [MarkdownSubsetParser.parseInline] 互逆：
/// 纯文本中的语法标记一律转义，保证「字面内容」往返不变形。
String serializeInline(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => _escapeText(text),
      InlineStrong(:final children) => '**${serializeInline(children)}**',
      InlineEm(:final children) => '*${serializeInline(children)}*',
      InlineUnderline(:final children) => '<u>${serializeInline(children)}</u>',
      InlineCode(:final code) => '`$code`',
      InlineLink(:final label, :final url, :final autolink) =>
        autolink ? url : '[${_escapeText(label)}]($url)',
      InlineStrikethrough(:final children) => '~~${serializeInline(children)}~~',
      InlineHighlight(:final children) => '==${serializeInline(children)}==',
    }).join();

/// 块 → Markdown 子集串。与 [MarkdownSubsetParser.parse] 互逆（三出口护栏
/// 之 serialize，SSOT：docs/design/rich-text-component.md §5）。
String serializeBlock(RichBlock block) => switch (block) {
      HeadingBlock(:final level, :final inline) =>
        '${'#' * level} ${serializeInline(inline)}',
      ParagraphBlock(:final inline) => serializeInline(inline),
      QuoteBlock(:final children) => children
          .map(serializeBlock)
          .map((md) => md.split('\n').map((l) => '> $l').join('\n'))
          // 子块间补空引用行（`>`），否则重解析时相邻段落会并段
          .join('\n>\n'),
      ListBlock(:final ordered, :final items) =>
        items.asMap().entries.map((e) {
          final lines = e.value.lines;
          final first = serializeInline(lines.first);
          final done = e.value.done;
          final head = done != null
              ? '- [${done ? 'x' : ' '}] $first'
              : (ordered ? '${e.key + 1}. $first' : '- $first');
          final cont = lines.skip(1).map((l) => '  ${serializeInline(l)}').join('\n');
          return cont.isEmpty ? head : '$head\n$cont';
        }).join('\n'),
      CodeBlock(:final code, :final language) =>
        '```${language ?? ''}\n$code\n```',
      DividerBlock() => '---',
      // 媒体块出口标准 Markdown 链接语法，MCP 桌面端零感知（§2）；
      // label/alt 原话直出，禁注入类型前缀（往返幂等）
      ImageBlock(:final url, :final alt) => '![${_escapeText(alt)}]($url)',
      AudioBlock(:final url, :final label) => '[${_escapeText(label)}]($url)',
      VideoBlock(:final url, :final label) => '[${_escapeText(label)}]($url)',
      TableBlock(:final header, :final rows, :final align) =>
        _serializeTable(header, rows, align),
    };

/// 表格 → Markdown 子集串（GFM 管线语法；无尾随换行，交由 [serializeBlocks] 块间空行）。
String _serializeTable(
  List<String> header,
  List<List<String>> rows,
  List<TableAlign>? align,
) {
  String row(List<String> cells) => '| ${cells.join(' | ')} |';
  final a = align ?? [for (final _ in header) TableAlign.left];
  final sep = '| ${a.map((al) => switch (al) {
        TableAlign.center => ':---:',
        TableAlign.right => '---:',
        TableAlign.left => ':---',
      }).join(' | ')} |';
  final buf = StringBuffer()
    ..writeln(row(header))
    ..writeln(sep);
  for (final r in rows) {
    buf.writeln(row(r));
  }
  return buf.toString().trimRight();
}

/// 块列表 → Markdown 子集串（块间空行分隔；编辑器回写唯一出口）。
String serializeBlocks(List<RichBlock> blocks) =>
    blocks.map(serializeBlock).join('\n\n');

// ---------- 解析 ----------

/// 富文本解析器接口。
abstract class RichTextParser {
  /// Markdown 子集 → 块树。永不抛异常，永不丢内容。
  List<RichBlock> parse(String markdown);

  /// 行内解析（供外部复用，如标题文案）。
  List<InlineNode> parseInline(String text);
}

/// Markdown 子集默认实现（纯函数，可单测）。
class MarkdownSubsetParser implements RichTextParser {
  const MarkdownSubsetParser();

  static final RegExp _fence = RegExp(r'^```(\w*)\s*$');
  static final RegExp _divider = RegExp(r'^\s*(?:---|\*\*\*|___)\s*$');
  static final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _quote = RegExp(r'^\s*>\s?');
  static final RegExp _bullet = RegExp(r'^\s*[-*+]\s+(.*)$');
  static final RegExp _ordered = RegExp(r'^\s*\d+[.)]\s+(.*)$');

  /// 整行即媒体的两种形态（rich-text-media.md §2：只识别「整行即媒体」，
  /// 段落中间混排降级 InlineLink）。
  static final RegExp _imageLine = RegExp(r'^!\[([^\]]*)\]\(([^)]*)\)\s*$');
  static final RegExp _linkLine = RegExp(r'^\[([^\]]*)\]\(([^)]*)\)\s*$');

  /// 列表项里的待办标记：`[ ]` / `[x]`。
  static final RegExp _todo = RegExp(r'^\[([ xX])\]\s+(.*)$');

  /// 行内合并正则（与 [inlineSpansOf] 共用单一事实源，分组号见 §3.6 ②）：
  /// 转义 → 自动链接 → 粗斜体 → 粗体 → 斜体 → 下划线 → 删除线 → 高亮 → 链接。
  /// 行内码（`code`）不在此正则内——走 [_extractCode] 预处理双扫描（防回溯）。
  static final RegExp _inlinePattern = RegExp(
    r'\\([\\`*_\[])' // 1 转义：`\X` → 字面 X
    r'|(https?://[^\s<>()]+|www\.[^\s<>()]+|mailto:[^\s<>()]+)' // 2 自动链接（裸 url/www./mailto:）
    r'|(\*\*\*)(.+?)\*\*\*' // 3,4 粗斜体（插在粗体前，最长匹配优先）
    r'|(\*\*|__)(.+?)\5' // 5,6 粗体（\5 反向引用粗体定界符）
    r'|(\*|_)(.+?)\7' // 7,8 斜体（\7 反向引用斜体定界符）
    r'|<u>(.+?)</u>' // 9 下划线
    r'|\~\~(.+?)\~\~' // 10 删除线
    r'|==([^\s=]+(?:\s+[^\s=]+)*)==' // 11 高亮（两侧非空白非=）
    r'|!?\[([^\]]*)\]\(([^)]*)\)', // 12,13 链接
    dotAll: true,
  );

  /// 行内码双扫描：先定位连续反引号定界符（`+），再找同长度闭合——线性时间，
  /// 无回溯（§3.6，弃正则防灾难性回溯）。返回 (start, end, content)，end 为闭合 run 之后。
  static List<(int, int, String)> _extractCode(String text) {
    final out = <(int, int, String)>[];
    var i = 0;
    while (i < text.length) {
      if (text[i] != '`') {
        i++;
        continue;
      }
      var k = 0;
      while (i + k < text.length && text[i + k] == '`') {
        k++;
      }
      final openStart = i;
      i += k;
      var j = i;
      var found = false;
      while (j < text.length) {
        if (text[j] == '`') {
          var m = 0;
          while (j + m < text.length && text[j + m] == '`') {
            m++;
          }
          if (m == k) {
            out.add((openStart, j + k, text.substring(openStart + k, j)));
            i = j + k;
            found = true;
            break;
          }
          j += m;
          continue;
        }
        j++;
      }
      if (!found) i = openStart + k;
    }
    return out;
  }

  /// 行内正则命中 → [InlineNode]（分组号对应 [_inlinePattern]）。
  static InlineNode _inlineNodeFromMatch(RegExpMatch m) {
    if (m.group(1) != null) {
      return InlineText(m.group(1)!); // 转义
    } else if (m.group(2) != null) {
      return InlineLink(label: m.group(2)!, url: m.group(2)!, autolink: true);
    } else if (m.group(4) != null) {
      return InlineStrong([InlineEm(const MarkdownSubsetParser().parseInline(m.group(4)!))]);
    } else if (m.group(6) != null) {
      return InlineStrong(const MarkdownSubsetParser().parseInline(m.group(6)!));
    } else if (m.group(8) != null) {
      return InlineEm(const MarkdownSubsetParser().parseInline(m.group(8)!));
    } else if (m.group(9) != null) {
      return InlineUnderline(const MarkdownSubsetParser().parseInline(m.group(9)!));
    } else if (m.group(10) != null) {
      return InlineStrikethrough(const MarkdownSubsetParser().parseInline(m.group(10)!));
    } else if (m.group(11) != null) {
      return InlineHighlight(const MarkdownSubsetParser().parseInline(m.group(11)!));
    } else if (m.group(12) != null) {
      return InlineLink(label: _unescape(m.group(12)!), url: m.group(13) ?? '');
    }
    return InlineText(m.group(0)!);
  }

  @override
  List<RichBlock> parse(String markdown) {
    final lines = markdown.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');

    // R3 第一遍：收集引用定义 `[id]: url`（id 大小写不敏感），定义行作 meta 剥离，不渲染残壳。
    final refDefs = <String, String>{};
    final body = <String>[];
    final defRe = RegExp(r'^\s*\[([^\]]+)\]:\s*(\S+)');
    for (final line in lines) {
      final m = defRe.firstMatch(line);
      if (m != null) {
        refDefs[m.group(1)!.toLowerCase()] = m.group(2)!;
      } else {
        body.add(line);
      }
    }

    // R3 第二遍：已识别的 `[text][id]` 重写为 `[text](url)`（沿用既有链接正则）；
    // 孤立 `[text][id]`（id 无定义）留字面——R1 护城河由动作层标注，解析器不静默吞。
    final resolved = refDefs.isEmpty
        ? body.join('\n')
        : _resolveRefLinks(body.join('\n'), refDefs);
    return _parseBlocks(resolved.split('\n'));
  }

  /// R3：[label][id] → [label](url)；id 未定义则保留原串。
  static String _resolveRefLinks(String text, Map<String, String> refDefs) {
    final refRe = RegExp(r'\[([^\]]*)\]\[([^\]]*)\]');
    return text.replaceAllMapped(refRe, (m) {
      final url = refDefs[m.group(2)!.toLowerCase()];
      if (url == null) return m.group(0)!;
      return '[${m.group(1)}]($url)';
    });
  }

  /// 责任链注册表：顺序严格对齐旧版 if-else 优先级，段落永远垫底兜底。
  static final List<_BlockSyntax> _syntaxes = [
    _FenceSyntax(),
    _DividerSyntax(),
    _TableSyntax(),
    _HeadingSyntax(),
    _QuoteSyntax(),
    _ListSyntax(),
    _ImageLineSyntax(),
    _MediaLinkSyntax(),
    _ParagraphSyntax(),
  ];

  /// Markdown → 块树（责任链调度）。静态化以便 [_QuoteSyntax] 递归复用（陷阱 G）。
  static List<RichBlock> _parseBlocks(List<String> lines) {
    final reader = _LineReader(lines);
    final blocks = <RichBlock>[];

    while (!reader.isDone) {
      // 空行是块间隙：跳过，且绝不并入段落（陷阱 C）
      if (reader.peek()!.trim().isEmpty) {
        reader.advance();
        continue;
      }

      final startIndex = reader.index;
      var matched = false;
      for (final syntax in _syntaxes) {
        if (syntax.canParse(reader)) {
          blocks.add(syntax.parse(reader));
          matched = true;
          break;
        }
      }

      // 陷阱 F：死循环护栏（对齐旧版「空 buf 只推进、不产块」的语义）
      if (!matched) {
        // 段落恒兜底，此分支实际不可达；真发生也只推进防卡死
        reader.advance();
        continue;
      }
      if (reader.index == startIndex) {
        // 语法命中却未推进读针：强制前进，不额外产块
        reader.advance();
      }
    }
    return blocks;
  }

  /// 块起始判定（静态化，供 [_ParagraphSyntax] 调用；陷阱 A）。
  static bool _isBlockStart(String line) =>
      _fence.hasMatch(line) ||
      _divider.hasMatch(line) ||
      _heading.hasMatch(line) ||
      _quote.hasMatch(line) ||
      _bullet.hasMatch(line) ||
      _ordered.hasMatch(line) ||
      _imageLine.hasMatch(line) ||
      // 媒体链接行才算块起始（普通链接行仍并入段落，保持既有行为）
      (_linkLine.hasMatch(line) &&
          classifyMediaUrl(_linkLine.firstMatch(line)!.group(2)!) !=
              MediaSuffix.unknown);

  // ---- 表格（GFM 官方扩展，§3.6 ④）----
  /// 表格起始：当前行是表行（含 `|`）且下一行是分隔线（`:?-+:?` 由 `|` 分隔）。
  static bool _isTableStart(List<String> lines, int i) {
    if (i + 1 >= lines.length) return false;
    return _isRowLine(lines[i]) && _isSeparatorLine(lines[i + 1]);
  }

  static bool _isRowLine(String line) => line.trim().contains('|');

  static bool _isSeparatorLine(String line) {
    final t = line.trim();
    if (!t.contains('|')) return false;
    final noPipes = t.replaceAll('|', '');
    if (!noPipes.contains('-')) return false;
    return RegExp(r'^[\s:\-]+$').hasMatch(noPipes);
  }

  static List<String> _splitRow(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|').map((c) => c.trim()).toList();
  }

  static TableAlign _alignOf(String sep) {
    final t = sep.trim();
    final left = t.startsWith(':');
    final right = t.endsWith(':');
    if (left && right) return TableAlign.center;
    if (right) return TableAlign.right;
    return TableAlign.left;
  }

  static (TableBlock, int) _parseTable(List<String> lines, int i) {
    final header = _splitRow(lines[i]);
    final seps = _splitRow(lines[i + 1]);
    final align = [for (final s in seps) _alignOf(s)];
    final rows = <List<String>>[];
    var j = i + 2;
    while (j < lines.length && _isRowLine(lines[j])) {
      final cells = _splitRow(lines[j]);
      if (cells.length != header.length) break; // 列数不一致则停止（防吞后续）
      rows.add(cells);
      j++;
    }
    return (TableBlock(header: header, rows: rows, align: align), j - i);
  }

  /// 列表项构造（静态化，供 [_ListSyntax] 调用；陷阱 A）。
  ///
  /// [content] 口径严格沿用旧版，两种调用不可混：
  /// - 列表项：传 `_bullet`/`_ordered` 抓出的**剥离前缀后**文本；
  /// - 裸待办行：传**原始行**（`[ ] xxx`），由 [_todo] 再剥一层。
  static ListItem _listItemImpl(String content) {
    final todo = _todo.firstMatch(content);
    if (todo != null) {
      final mark = todo.group(1)!;
      return ListItem([_parseInlineImpl(todo.group(2)!)], done: mark != ' ');
    }
    return ListItem([_parseInlineImpl(content)]);
  }

  /// 行内解析实现（静态化，供块语法责任链调用；陷阱 A）。
  ///
  /// 匹配顺序即优先级：`\X` 转义最先（serialize 的字面出口），`**` 先于 `*`，
  /// 避免 `**粗**` 被拆成两个斜体。返回前合并相邻纯文本节点（规范形，
  /// 保证 parse→serialize→parse 块树逐节点相等）。
  ///
  /// 静态化仅为让嵌套的 [_BlockSyntax] 能调用，逻辑与旧版逐行等价。
  @override
  List<InlineNode> parseInline(String text) => _parseInlineImpl(text);

  /// [parseInline] 的静态实现体（旧版 parseInline 原样搬移）。
  static List<InlineNode> _parseInlineImpl(String text) {
    if (text.isEmpty) return const <InlineNode>[InlineText('')];

    final codeSpans = _extractCode(text);
    bool overlapsCode(int s, int e) =>
        codeSpans.any((c) => s < c.$2 && c.$1 < e);

    // 事件化：行内码与正则命中按文档序排布，互不重叠（命中与码区间重叠则丢弃该命中）。
    final events = <_InlineEvent>[];
    for (final c in codeSpans) {
      events.add(_InlineEvent(c.$1, c.$2, code: c.$3));
    }
    for (final m in _inlinePattern.allMatches(text)) {
      if (overlapsCode(m.start, m.end)) continue;
      events.add(_InlineEvent(m.start, m.end, match: m));
    }
    events.sort((a, b) => a.start.compareTo(b.start));

    final out = <InlineNode>[];
    var pos = 0;
    for (final ev in events) {
      if (ev.start > pos) out.add(InlineText(text.substring(pos, ev.start)));
      if (ev.code != null) {
        out.add(InlineCode(ev.code!));
      } else {
        out.add(_inlineNodeFromMatch(ev.match!));
      }
      pos = ev.end;
    }
    if (pos < text.length) out.add(InlineText(text.substring(pos)));
    return out.isEmpty ? [InlineText(text)] : _mergeText(out);
  }

  /// 合并相邻 [InlineText]（转义会产生碎片节点，合并为规范形）。
  static List<InlineNode> _mergeText(List<InlineNode> nodes) {
    final out = <InlineNode>[];
    for (final n in nodes) {
      final last = out.isEmpty ? null : out.last;
      if (n is InlineText && last is InlineText) {
        out[out.length - 1] = InlineText(last.text + n.text);
      } else {
        out.add(n);
      }
    }
    return out;
  }

  static String _unescape(String s) =>
      s.replaceAllMapped(RegExp(r'\\([\\`*_\[\]])'), (m) => m.group(1)!);
}

// ---------- 块解析：_LineReader + _BlockSyntax 责任链 ----------
//
// 纯架构解耦：仅把原先的下标 while/if-else 换成流式 Reader + 策略注册表。
// 对外 parse()/parseInline、RichBlock/InlineNode 模型、serialize*/inlineSpansOf
// 全部零改动。本轮严格「bug-for-bug compatible」：不扩充任何语法（含多行列表），
// 行为与旧版逐块对齐。

/// 流式行读取器：替代手写 `i++` 下标循环。
///
/// 暴露 [lines]/[index] 供表格语法直接复用既有的 [_parseTable]
/// （陷阱 E：避免重写「单元格数不一致即停止」的边界逻辑）。
class _LineReader {
  _LineReader(this.lines);

  final List<String> lines;
  int index = 0;

  bool get isDone => index >= lines.length;

  /// 向前看 [offset] 行（表格判定需二行前瞻，故必须带 offset）。
  String? peek([int offset = 0]) {
    final at = index + offset;
    return at >= 0 && at < lines.length ? lines[at] : null;
  }

  String advance() => lines[index++];

  void advanceBy(int count) => index += count;
}

/// 块语法策略（责任链）：[canParse] 嗅探首行，[parse] 消费并产出 [RichBlock]。
///
/// 注册顺序即优先级（特殊在前、段落永远垫底），与旧版 if-else 链严格一致。
abstract class _BlockSyntax {
  bool canParse(_LineReader r);

  RichBlock parse(_LineReader r);
}

/// 代码块：围栏内原样保留，不解析行内。
class _FenceSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) =>
      MarkdownSubsetParser._fence.hasMatch(r.peek()!);

  @override
  RichBlock parse(_LineReader r) {
    final open = r.advance();
    final lang = MarkdownSubsetParser._fence.firstMatch(open)!.group(1)!;
    final buf = <String>[];
    while (!r.isDone && !MarkdownSubsetParser._fence.hasMatch(r.peek()!)) {
      buf.add(r.advance());
    }
    if (!r.isDone) r.advance(); // 消费闭合围栏（缺失时按到文末，旧版行为）
    return CodeBlock(code: buf.join('\n'), language: lang.isEmpty ? null : lang);
  }
}

/// 分隔线。
class _DividerSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) =>
      MarkdownSubsetParser._divider.hasMatch(r.peek()!);

  @override
  RichBlock parse(_LineReader r) {
    r.advance();
    return const DividerBlock();
  }
}

/// 表格（GFM）：当前行是表行且下一行是分隔线。
class _TableSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) =>
      MarkdownSubsetParser._isTableStart(r.lines, r.index);

  @override
  RichBlock parse(_LineReader r) {
    // 复用既有 _parseTable，零重写即零分歧（陷阱 E）
    final (block, consumed) =
        MarkdownSubsetParser._parseTable(r.lines, r.index);
    r.advanceBy(consumed);
    return block;
  }
}

/// 标题。
class _HeadingSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) =>
      MarkdownSubsetParser._heading.hasMatch(r.peek()!);

  @override
  RichBlock parse(_LineReader r) {
    final m = MarkdownSubsetParser._heading.firstMatch(r.advance())!;
    return HeadingBlock(
      level: m.group(1)!.length,
      inline: MarkdownSubsetParser._parseInlineImpl(m.group(2)!),
    );
  }
}

/// 引用块：剥离 `>` 后递归走同一个 [_parseBlocks]，保证嵌套结构与行内口径一致（陷阱 G）。
class _QuoteSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) =>
      MarkdownSubsetParser._quote.hasMatch(r.peek()!);

  @override
  RichBlock parse(_LineReader r) {
    final buf = <String>[];
    while (!r.isDone && MarkdownSubsetParser._quote.hasMatch(r.peek()!)) {
      buf.add(r.advance().replaceFirst(MarkdownSubsetParser._quote, ''));
    }
    return QuoteBlock(MarkdownSubsetParser._parseBlocks(buf));
  }
}

/// 列表（含裸待办行，支持多行项与裸待办并入前序列表）。
///
/// 保留旧版两条特征（陷阱 B——任何「纠正」都会打破往返幂等）：
/// 1. **有序列表会吸收后续的无序项，无序列表不吸收有序项**；
/// 2. 裸待办行 `[ ] xxx` 归入列表（① 并入前序列表），且传**原始行**给
///    [_listItemImpl]（由 [_todo] 再剥一层 `[ ] `），与列表项传「剥离后文本」口径不同。
///
/// ② 多行项：列表项吸收益「≥2 空格缩进、非块起始、非新列表项」的续行，归入
/// 同一 [ListItem.lines]（markdown 中以缩进续行表示）。续行不入段落判决。
class _ListSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) {
    final line = r.peek()!;
    return MarkdownSubsetParser._bullet.hasMatch(line) ||
        MarkdownSubsetParser._ordered.hasMatch(line) ||
        MarkdownSubsetParser._todo.hasMatch(line); // 裸待办（与 _todo 同型）
  }

  /// 续行判定：≥2 空格缩进、非块起始、非新列表项（含裸待办）才并入前序项。
  static bool _isContinuation(_LineReader r, String line) {
    if (line.trim().isEmpty) return false;
    if (!line.startsWith('  ')) return false; // 必须缩进（≥2 空格）
    if (MarkdownSubsetParser._isBlockStart(line)) return false; // 标题/引用/表格等
    if (MarkdownSubsetParser._isTableStart(r.lines, r.index)) return false;
    if (MarkdownSubsetParser._bullet.hasMatch(line) ||
        MarkdownSubsetParser._ordered.hasMatch(line) ||
        MarkdownSubsetParser._todo.hasMatch(line)) {
      return false; // 新列表项（含裸待办）另起项
    }
    return true;
  }

  @override
  RichBlock parse(_LineReader r) {
    final isOrdered = MarkdownSubsetParser._ordered.hasMatch(r.peek()!);
    final items = <ListItem>[];
    while (!r.isDone) {
      final line = r.peek()!;
      // ② 续行：已有前序项且本行是缩进续行 → 并入当前项
      if (items.isNotEmpty && _isContinuation(r, line)) {
        final cont = line.replaceFirst(RegExp(r'^ +'), '');
        items.last.lines.add(MarkdownSubsetParser._parseInlineImpl(cont));
        r.advance();
        continue;
      }
      final m = isOrdered
          ? (MarkdownSubsetParser._ordered.firstMatch(line) ??
              MarkdownSubsetParser._bullet.firstMatch(line))
          : MarkdownSubsetParser._bullet.firstMatch(line);
      if (m != null) {
        items.add(MarkdownSubsetParser._listItemImpl(m.group(1)!));
        r.advance();
        continue;
      }
      // ① 裸待办并入前序列表：当前行是裸待办（_todo 命中但非 bullet/ordered）
      if (MarkdownSubsetParser._todo.hasMatch(line)) {
        items.add(MarkdownSubsetParser._listItemImpl(line)); // 传原始行
        r.advance();
        continue;
      }
      break;
    }
    return ListBlock(ordered: isOrdered, items: items);
  }
}

/// 整行图片 `![alt](url)`。
class _ImageLineSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) =>
      MarkdownSubsetParser._imageLine.hasMatch(r.peek()!);

  @override
  RichBlock parse(_LineReader r) {
    final m = MarkdownSubsetParser._imageLine.firstMatch(r.advance())!;
    return ImageBlock(
      url: m.group(2)!,
      alt: MarkdownSubsetParser._unescape(m.group(1)!),
    );
  }
}

/// 整行媒体链接 `[label](url)` 且后缀命中白名单；未命中则落回段落（不丢内容）。
class _MediaLinkSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) {
    final m = MarkdownSubsetParser._linkLine.firstMatch(r.peek()!);
    return m != null && classifyMediaUrl(m.group(2)!) != MediaSuffix.unknown;
  }

  @override
  RichBlock parse(_LineReader r) {
    final m = MarkdownSubsetParser._linkLine.firstMatch(r.advance())!;
    final url = m.group(2)!;
    final media = classifyMediaUrl(url);
    if (media == MediaSuffix.audioPlayable || media == MediaSuffix.audioDegrade) {
      return AudioBlock(
        url: url,
        label: MarkdownSubsetParser._unescape(m.group(1)!),
      );
    }
    return VideoBlock(
      url: url,
      label: MarkdownSubsetParser._unescape(m.group(1)!),
    );
  }
}

/// 段落：恒兜底（[canParse] 恒 true），连续吃非空且非块起始的行。
class _ParagraphSyntax implements _BlockSyntax {
  @override
  bool canParse(_LineReader r) => true;

  @override
  RichBlock parse(_LineReader r) {
    final buf = <String>[];
    // 首行无条件消费：段落语法的基本前置假设是「首行即段落正文」。
    // 正常路径下首行必非空且非块起始（主循环已跳过空行、且块起始行必被
    // 前面的语法认领），故此处与「先判再吃」等价；但若将来 canParse 与
    // _isBlockStart 出现偏差，可保证仍会推进读针，绝不产出空 ParagraphBlock。
    buf.add(r.advance());
    while (!r.isDone) {
      final line = r.peek()!;
      if (line.trim().isEmpty) break;
      if (MarkdownSubsetParser._isBlockStart(line)) break;
      if (MarkdownSubsetParser._isTableStart(r.lines, r.index)) break;
      buf.add(r.advance());
    }
    return ParagraphBlock(
      MarkdownSubsetParser._parseInlineImpl(buf.join('\n')),
    );
  }
}


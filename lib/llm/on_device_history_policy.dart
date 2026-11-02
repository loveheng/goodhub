/// 端侧历史策略族（HistoryPolicy，策略模式，2026-11-02）。
///
/// **背景（用户拍板）**：小模型（Gemma3-1B 真机）带历史时出现「12222」式退化
/// 输出，历史拼装从单一「丢最老滑窗」升级为可切换策略族。**两侧通用、每侧
/// 默认不同**：云端/混合装配默认 ①（`buildOnDeviceChatPromptJson` 同步入口，
/// 行为零变化）；端侧经 `buildOnDeviceChatPromptJsonAsync` 可切任意策略。
///
/// **窗口分档立法（用户拍板 2026-11-02）**：拼装丰富度由模型窗口决定——
/// `< 2k` 强制 ①（②③ 对该档无意义：700t 历史内锚点与近窗几乎重叠，摘要
/// 本身比历史还贵）；`2k~4k` 可切 ②；`≥ 4k` 开放 ③ 实验位。档位路由归
/// 消费方（模型目录 `contextTokens` 在场），本文件只提供策略本体。
///
/// 参考对照（2026-11-02 调研）：google-ai-edge/gallery `agent/sessions/`
/// 的 `ContextCompactor` 策略族（摘要默认 + 截断兜底，0.9 触发阈值、摘要
/// 失败降级）。形态差异：他们进程内持有 Conversation、压缩=整会话重置；
/// 我们跨 AIDL 无状态、每请求重拼 promptJson——只借鉴参数与降级结构。
///
/// 纯逻辑件（无平台依赖）：单测见 `test/llm/on_device_history_policy_test.dart`。
///
/// ③ 的摘要器经 [OnDeviceSummarizer] 注入（消费方接 `on_device_capability`
/// 的 `complete()` 原语），本文件不 import 引擎面——防 import 环。
library;

/// 历史轮次中立元组（role, content）——与 `on_device_chat_prompt.dart`
/// 的轮次表示同构（role ∈ user|assistant，system 由构造器单独承载不进策略）。
typedef OnDeviceHistoryTurn = (String, String);

/// 摘要器注入面（③ 实验位专用）：输入被驱逐轮次，输出摘要文本。
/// 抛异常 / 返回空白 = 摘要失败，由策略回退兜底层。
typedef OnDeviceSummarizer = Future<String> Function(
    List<OnDeviceHistoryTurn> evictedTurns);

/// 端侧历史策略接口：在字符预算内挑选保留的历史轮次。
///
/// 契约：
/// - 输入 `turns` 为时序轮次（不含 system，system 合并与清洗归构造器）；
/// - 返回值为输入的**子序列**（保序、不改写内容——③ 的摘要轮除外）；
/// - **末轮（当前提问）不可丢**，除非它单独就超预算（此时行为与 ① 对齐）；
/// - 实现必须无副作用（③ 的摘要推理除外，其结果只进本轮 prompt）。
abstract interface class OnDeviceHistoryPolicy {
  Future<List<OnDeviceHistoryTurn>> select(
      List<OnDeviceHistoryTurn> turns, int budget);

  /// true = 本策略要求**连 system 指令一起丢**（真裸 prompt）。默认 false；
  /// 仅 ⓪ 对照实验策略置真（用户拍板 2026-11-03：裸 prompt 语义 = 无历史、
  /// 无 system、只保当前提问——与官方 Gallery 裸问题完全同形，归因实验
  /// 才有单变量可比性）。
  bool get dropsSystem => false;
}

/// ① 滑窗丢最老（存量默认策略）：超预算从最早一轮起丢，至少保留末轮。
///
/// **行为零变化约束（用户拍板 2026-11-02）**：本策略 = 原
/// `buildOnDeviceChatPromptJson` 内联裁剪逻辑的**原样封装**——云端/混合
/// 路径行为钉死在此（算法单源 = [dropOldestWithinBudget]）。
class DropOldestHistoryPolicy implements OnDeviceHistoryPolicy {
  const DropOldestHistoryPolicy();

  @override
  bool get dropsSystem => false;

  @override
  Future<List<OnDeviceHistoryTurn>> select(
          List<OnDeviceHistoryTurn> turns, int budget) async =>
      dropOldestWithinBudget(turns, budget);
}

/// ① 算法单源：滑窗丢最老的纯函数（同步入口与策略共用，防双源漂移）。
List<OnDeviceHistoryTurn> dropOldestWithinBudget(
    List<OnDeviceHistoryTurn> turns, int budget) {
  var start = 0;
  var total = turns.fold<int>(0, (sum, t) => sum + t.$2.length);
  while (start < turns.length - 1 && total > budget) {
    total -= turns[start].$2.length;
    start++;
  }
  return turns.sublist(start);
}

/// ⓪ 裸 prompt（最简策略，**真裸**）：历史全丢、system 指令也丢，
/// 只保留末轮（当前提问）。
///
/// 用途：**对照实验策略**——与官方 Gallery 裸问题完全同形（无 system、
/// 无历史），「12222」归因的单变量钉子（2026-11-03 用户拍板：⓪ 连 system
/// 一起丢——此前「保 system」形态导致对照始终带着长指令变量，实验不纯）；
/// 也是「无状态单发」消费面（如端侧原语的极端省钱档）。
class BarePromptHistoryPolicy implements OnDeviceHistoryPolicy {
  const BarePromptHistoryPolicy();

  @override
  bool get dropsSystem => true;

  @override
  Future<List<OnDeviceHistoryTurn>> select(
      List<OnDeviceHistoryTurn> turns, int budget) async {
    if (turns.isEmpty) return const [];
    return [turns.last];
  }
}

/// ② 锚点+近窗：永久保留首轮（任务锚点）+ 从最新往前的近窗，共享预算。
///
/// 差异化补充（Edge Gallery 无此策略，其截断也是从头丢、仅靠 system 回填）：
/// 长对话丢锚点后「任务定义缺失 → 模型失去约束」是②针对的退化形态。
/// 适用档位 ≥ 2k 窗口（< 2k 时锚点配额会砍掉近窗 1/4~1/3，得不偿失）。
///
/// 规则：
/// - 首轮作锚点；锚点超自身配额（[anchorShareRatio] × 预算）→ 整体回退 ①
///   （截断锚点会产出残句，比丢了更糟）；
/// - 近窗从最新往前收（收满剩余预算为止），**保证含末轮**；收不进末轮 →
///   回退 ①（与 ① 「至少保留末轮」语义对齐）；
/// - 交替性：锚点为 user 时序列天然 user 开头；锚点为 assistant（异常序）→
///   回退 ①。
class AnchorAndRecentHistoryPolicy implements OnDeviceHistoryPolicy {
  const AnchorAndRecentHistoryPolicy();

  @override
  bool get dropsSystem => false;

  /// 锚点预算配额占比（默认 0.3：≥2k 窗口下锚点 ≈ 150~600 字符）。
  static const double anchorShareRatio = 0.3;

  @override
  Future<List<OnDeviceHistoryTurn>> select(
      List<OnDeviceHistoryTurn> turns, int budget) async {
    if (turns.length <= 1) return turns;
    final anchor = turns.first;
    if (anchor.$1 != 'user') return dropOldestWithinBudget(turns, budget);
    final anchorBudget = (budget * anchorShareRatio).floor();
    if (anchor.$2.length > anchorBudget) {
      return dropOldestWithinBudget(turns, budget);
    }
    var remaining = budget - anchor.$2.length;
    final recent = <OnDeviceHistoryTurn>[];
    for (final t in turns.reversed) {
      if (identical(t, anchor)) break;
      if (t.$2.length > remaining) break;
      recent.insert(0, t);
      remaining -= t.$2.length;
    }
    if (recent.isEmpty || recent.last != turns.last) {
      // 末轮收不进近窗 → 近窗为空/残缺，回退 ①（至少保末轮的存量语义）。
      return dropOldestWithinBudget(turns, budget);
    }
    return [anchor, ...recent];
  }
}

/// ③ 滚动摘要（**实验位，默认关**）：被驱逐轮次压成一条摘要轮回注。
///
/// 借鉴 Edge Gallery `SummarizationContextCompactor`：摘要预算动态推导、
/// 摘要失败/余量不足自动降级。本实现把「压缩」换成「驱逐+摘要回注」
/// （无会话可重置——跨 AIDL 无状态形态）。
///
/// 规则：
/// - 轮次总量未超预算 → 原样透传（不推理，零成本）；
/// - 近窗从最新往前收至 [recentShareRatio] × 预算，其余为被驱逐段交
///   [summarize]；**摘要只在 ≥ 4k 窗口启用**（1B 模型摘要质量不可信、
///   摘要推理比历史更贵——档位路由归消费方，本策略不自带档位闸）；
/// - 摘要轮 role = user（附 `kHistorySummaryTag` 标记），其后紧跟 assistant
///   才满足模板交替——近窗收完后丢**引导 user 轮**（末轮永不丢）直至首条
///   为 assistant；凑不出 assistant 开头的近窗 → 回退 [fallback]（①）；
/// - 摘要失败（抛异常/空白）或摘要本身超配额（[summaryShareRatio]，超长
///   截断——截断摘要优于摘要失败）→ 失败回退 [fallback]（①）。
class RollingSummaryHistoryPolicy implements OnDeviceHistoryPolicy {
  const RollingSummaryHistoryPolicy({
    required this.summarize,
    this.fallback = const DropOldestHistoryPolicy(),
  });

  /// 摘要器（消费方注入端侧能力原语）。
  final OnDeviceSummarizer summarize;

  @override
  bool get dropsSystem => false;

  /// 降级策略（默认 ① 滑窗）。
  final OnDeviceHistoryPolicy fallback;

  /// 近窗预算占比（默认 0.6：摘要轮 ≤ 0.25 + 交替余量）。
  static const double recentShareRatio = 0.6;

  /// 摘要文本配额占比（超长截断）。
  static const double summaryShareRatio = 0.25;

  @override
  Future<List<OnDeviceHistoryTurn>> select(
      List<OnDeviceHistoryTurn> turns, int budget) async {
    final total = turns.fold<int>(0, (sum, t) => sum + t.$2.length);
    if (total <= budget) return turns;
    // 近窗：从最新往前收至 recentShareRatio × 预算（必含末轮，收不进 → 回退）。
    final recentBudget = (budget * recentShareRatio).floor();
    var remaining = recentBudget;
    final recent = <OnDeviceHistoryTurn>[];
    var evictedEnd = turns.length;
    for (var i = turns.length - 1; i >= 0; i--) {
      final t = turns[i];
      if (t.$2.length > remaining) break;
      recent.insert(0, t);
      remaining -= t.$2.length;
      evictedEnd = i;
    }
    if (recent.isEmpty || recent.last != turns.last) {
      return fallback.select(turns, budget);
    }
    final evicted = turns.sublist(0, evictedEnd);
    if (evicted.isEmpty) return turns;
    // 摘要（失败 → 回退 ①；[DEGRADE] 语义归调用方日志，策略本体保持纯逻辑）。
    String summary;
    try {
      summary = await summarize(evicted);
    } catch (_) {
      return fallback.select(turns, budget);
    }
    summary = summary.trim();
    if (summary.isEmpty) return fallback.select(turns, budget);
    final summaryCap = (budget * summaryShareRatio).floor();
    if (summary.length > summaryCap) {
      summary = '${summary.substring(0, summaryCap)}…';
    }
    // 交替性：摘要(user) 之后须 assistant 开头——丢近窗引导 user 轮（末轮不丢）。
    while (recent.length > 1 && recent.first.$1 != 'assistant') {
      recent.removeAt(0);
    }
    if (recent.first.$1 != 'assistant') {
      return fallback.select(turns, budget);
    }
    return [
      ('user', '$kHistorySummaryTag$summary'),
      ...recent,
    ];
  }
}

/// 摘要轮标记前缀（模型可见的段界提示；非 ChatML 控制 token，不触发清洗）。
const String kHistorySummaryTag = '【历史摘要】';

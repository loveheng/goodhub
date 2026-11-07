/// 会话轨道记录模型 + 序列化（extensibility-hardening S4 自
/// `lib/ui/components/dual_track_stream.dart` 下沉）：**内核认识轨道语义**的
/// 基础件——会话持久化不再是 UI 模型序列化（transcript 中立数据同款边界），
/// PC 回放 / 导入导出 / 内核级测试不再绕 UI 层。
///
/// **S4 数据/交互态分离矩阵**（15 子类逐一裁定；施工稿
/// `docs/design/extensibility-hardening.md` S4 前置清单）：
///
/// | 子类 | 数据（可持久化） | 交互态（UI 侧挂接） | 裁定 |
/// |---|---|---|---|
/// | TrackText | text | ChangeNotifier 流式 append（自管局部重绘） | 全体随迁 |
/// | TrackThinking | text + expanded | 同上 + toggle | 全体随迁 |
/// | TrackUser | text | — | 纯数据 |
/// | TrackCall | tool/phase/progressNote/preview/resultText/description | ChangeNotifier patch | 全体随迁 |
/// | TrackPlanConfirm | card（PlanProposalCard=coordinator 数据）/decision/decidedAt/lockedSummary | Completer（**惰性**） | 随迁 |
/// | TrackPlanResult | record | onResume 回调（不序列化） | 随迁 |
/// | TrackConfirm | pending/decision/decidedAt | Completer（**惰性**） | 随迁 |
/// | TrackBreaker | report/wall/lockedText/decidedAt | Completer（**惰性**） | 随迁 |
/// | TrackFence | info/decision/decidedAt | Completer（**惰性**） | 随迁 |
/// | TrackNote | text/danger/category | — | 纯数据 |
/// | TrackGuide | text/actionLabel | onAction（不可序列化，持久化前过滤） | 随迁 |
/// | TrackError | title/advice/detail/retried | onAction（恢复态锁定 null） | 随迁 |
/// | TrackMemoryCapsule | key/value/undone | onUndo（恢复态锁定 null） | 随迁 |
/// | TrackContextAttribution | memories/services/droppedCount | onItemExclude/onViewMemories | 随迁 |
/// | TrackElicitation | request/answer/decidedAt | Completer（**惰性**） | 随迁 |
///
/// 红线：**decode 不创建任何运行时瞬态**——5 个待决卡的 Completer 惰性化
/// （已决历史条目永不物化 Completer，仅活会话委托面 `await completer.future`
/// 时创建）；持久化格式字节级不变（codec 逐行搬移，格式钉 =
/// test/ui/track_codec_test.dart + test/coordinator/chat_track_model_test.dart）。
/// 渲染映射与交互生命周期仍住 UI（`dual_track_stream.dart`）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/notice_category.dart';
import '../mcp/elicitation.dart';
import 'fenced_cloud_engine.dart';
import 'permission_gateway.dart';
import 'plan_proposal_tool.dart';
import 'task_plan.dart';
import 'tool_breaker.dart';

/// 卡片生命周期相位（ui-design §3.2 左侧状态竖条语义色的映射源）。
/// S4 自 `call_card.dart` 迁入：数据模型承载（codec 持久化 phase.name），
/// 渲染组件经 import 消费（ui→coordinator 合法方向）。
enum CallCardPhase {
  /// 执行中（Started 即插卡；Emerald）。
  running,

  /// 疑似卡死（D4：无更新超阈值，只提示不自动中止；Amber）。
  stuck,

  /// 成功终态（Emerald 竖条 + 正文灰阶弱化）。
  success,

  /// 失败终态（Rose）。
  failed,

  /// 用户中止终态（Rose + 灰阶正文；与 failed 区分，architecture §10）。
  cancelled,
}

/// 轨道条目（页面编排记录；sealed 供渲染穷举）。
sealed class TrackEntry {
  const TrackEntry();
}

/// C6（page-beautify P3）：完成通告文本——据此把「✓ 任务完成」从 Run 概要
/// 折叠中摘出、单独 Emerald 成行（chat_page 与渲染件共此常量，防文本漂移）。
const String kTaskDoneNote = '✓ 任务完成';

/// A4（page-beautify P3）：首颗记忆胶囊的事前说明（chat_page onCapsule 幂等
/// 插入；恢复会话经序列化还原、不再触发插入）。
/// P2-12（2026-10-22）：思考轨表头的自述——「这是什么 + 影不影响结果」。
/// 与 [CloudThinkingDelta] 的展示 only 四不契约同口径（不进历史/不回放）。
const String kThinkingHint = '模型内部推理 · 不进对话历史，不影响结果';

const String kMemoryFirstNotice =
    // round-record（2026-10-31）：通告不再在阅读轨里呈现，说明句中的查看入口
    // 指向 AppBar「本轮记录」面板（系统通告 + 记忆同一处）。
    '模型从对话中提取了一条事实写入记忆（可逐条撤销；顶部「本轮记录」查看全部）';

/// 阅读轨文本（流式追加：页面往 [text] 写 delta）。
///
/// 自管件（window-slim P1-B/C/D 切片 C）：原页面 40ms 流控刷盘每帧整页
/// `setState` 只为刷新本条目文本——典型反模式。改由本件实现 [Listenable]，
/// [append] 写 delta 后仅自身通知，渲染侧经 `ListenableBuilder` 局部重绘，
/// 不再牵连整页重建（`StreamingRichText` 前缀块缓存仍收口细粒度）。
class TrackText extends TrackEntry with ChangeNotifier {
  TrackText(String initial) {
    text.write(initial);
  }

  final StringBuffer text = StringBuffer();

  /// 追加 delta 并通知自身监听者（仅本条目重绘，无整页 setState）。
  void append(String delta) {
    if (delta.isEmpty) return;
    text.write(delta);
    notifyListeners();
  }
}

/// 思考轨（2026-10-21 M1）：推理型云模型思维流（`reasoning_content`）的
/// **展示 only** 条目——内容不进历史/不回放（见 [CloudThinkingDelta] 契约）。
/// **默认收起**（用户拍板）：表头一行「思考过程 ▸」，点击展开/收起全文；
/// 持久化保留展开态（历史保真），恢复态按存档值呈现。
/// 自管件（同 TrackText 口径）：[append] 写 delta 后仅自身通知，渲染侧经
/// `ListenableBuilder` 局部重绘，不牵连整页重建。
class TrackThinking extends TrackEntry with ChangeNotifier {
  TrackThinking(String initial) {
    text.write(initial);
  }

  final StringBuffer text = StringBuffer();

  /// 展开态（默认收起；用户点击切换后持久化）。
  bool expanded = false;

  /// 追加 delta 并通知自身监听者（仅本条目重绘，无整页 setState）。
  void append(String delta) {
    if (delta.isEmpty) return;
    text.write(delta);
    notifyListeners();
  }

  /// 展开/收起切换。
  void toggle() {
    expanded = !expanded;
    notifyListeners();
  }
}

/// 用户轮次（发送即插卡）。
class TrackUser extends TrackEntry {
  const TrackUser(this.text);

  final String text;
}

/// 操作轨执行卡（CallCard 快照源；终态后页面不再 mutate）。
///
/// 自管件（window-slim P1-B/C/D 切片 C）：运行期相位/进度/预览/结果高频 mutate
/// 原每帧整页 `setState`——反模式。改由本件实现 [Listenable]，[patch] 改相位并
/// 仅自身通知，渲染侧经 `ListenableBuilder` 局部重绘。构造期直接赋值字段（如
/// 历史恢复解码）不触发通知，由随后整页重建读取，语义不变。
class TrackCall extends TrackEntry with ChangeNotifier {
  TrackCall({required this.tool});

  final String tool;
  CallCardPhase phase = CallCardPhase.running;
  String? progressNote;
  String preview = '';

  /// 终态结果全文（可展开查看；空 = 仅预览）。
  String resultText = '';

  /// A2（page-beautify）：服务端工具描述全文（run 起步由页面建映射注入；
  /// 恢复历史经 codec 还原）。CallCard 收起态显示首子句、可展开全文。
  String? description;

  /// 运行期更新相位/进度/预览/结果：合并写 + 单次自我通知（仅本卡局部重绘）。
  void patch({
    CallCardPhase? phase,
    String? progressNote,
    String? preview,
    String? resultText,
  }) {
    if (phase != null) this.phase = phase;
    if (progressNote != null) this.progressNote = progressNote;
    if (preview != null) this.preview = preview;
    if (resultText != null) this.resultText = resultText;
    notifyListeners();
  }
}

/// 任务计划批量确认卡（编排 B1；PlanProposalDelegate 待决挂起；确认/取消后
/// 锁定审计行终态）。
class TrackPlanConfirm extends TrackEntry {
  TrackPlanConfirm({required this.card});

  final PlanProposalCard card;

  /// 待决挂起（**惰性**：S4 分离矩阵——decode 的已决历史条目不创建运行时
  /// 瞬态，仅活会话委托面 `await completer.future` 时物化）。
  Completer<PlanProposalDecision>? _completer;
  Completer<PlanProposalDecision> get completer =>
      _completer ??= Completer<PlanProposalDecision>();
  PlanProposalDecision? decision;
  DateTime? decidedAt;

  /// 终态审计行（「✓ 已批准 N 项 · 剔除 M 项 · HH:mm」）。
  String? lockedSummary;
}

/// 计划执行聚合卡（编排 B1）：Run 收口台账呈现；onResume 不序列化
/// （恢复历史锁定为回看，不可续跑——可续跑仅存在于收口当刻的活会话）。
class TrackPlanResult extends TrackEntry {
  TrackPlanResult({required this.record, this.onResume});

  final PlanAggregateRecord record;
  VoidCallback? onResume;
}

/// L2 确认卡（GateDelegate 待决挂起；用户操作后锁定终态）。
class TrackConfirm extends TrackEntry {
  TrackConfirm({required this.pending});

  final ToolPendingConfirmation pending;

  /// 待决挂起（**惰性**，同 [TrackPlanConfirm.completer] 口径）。
  Completer<GateDecision>? _completer;
  Completer<GateDecision> get completer =>
      _completer ??= Completer<GateDecision>();
  GateDecision? decision;
  DateTime? decidedAt;
}

/// 熔断排查卡 / 步数墙卡。
class TrackBreaker extends TrackEntry {
  TrackBreaker.breaker(this.report) : wall = null;
  TrackBreaker.wall(this.wall) : report = null;

  final BreakerReport? report;
  final StepWallReport? wall;

  /// 待决挂起（**惰性**，同 [TrackPlanConfirm.completer] 口径）。
  Completer<Object?>? _completer;
  Completer<Object?> get completer => _completer ??= Completer<Object?>();
  String? lockedText;
  DateTime? decidedAt;
}

/// N7 围栏拦截卡（双选项）。
class TrackFence extends TrackEntry {
  TrackFence(this.info);

  final PiiMaskBlockInfo info;

  /// 待决挂起（**惰性**，同 [TrackPlanConfirm.completer] 口径）。
  Completer<bool>? _completer;
  Completer<bool> get completer => _completer ??= Completer<bool>();
  bool? decision;
  DateTime? decidedAt;
}

/// 通告行（收尾/错误/状态注记；danger = Rose）。
///
/// [category]（2026-10-31 后续治理）决定去向：事实类入「本轮记录」账本单槽、
/// 错误类回对话流内联、过程类不收纳仅瞬态 pill——见 [TrackNoticeCategory]。
/// 缺省 [TrackNoticeCategory.fact]（安全默认：漏标的非危险通告至少留在账本，
/// 不会被误丢）。
class TrackNote extends TrackEntry {
  const TrackNote(this.text,
      {required this.danger, this.category = TrackNoticeCategory.fact});

  final String text;
  final bool danger;
  final TrackNoticeCategory category;
}

/// 引导卡（ux-hardening P0-1 冷启动）：会话内可操作提示——正文 + 单一
/// 动作按钮（如未配置服务的「去配置」）。
/// **瞬态条目**：动作回调不可序列化，页面在持久化前过滤（恢复会话不出
/// 现引导卡，由页面按当前配置状态重插）；编码侧兜底为通告行防万一直插。
class TrackGuide extends TrackEntry {
  const TrackGuide({
    required this.text,
    required this.actionLabel,
    this.onAction,
  });

  final String text;
  final String actionLabel;

  /// 动作回调（null = 锁定态：仅展示标签，不渲染按钮）。
  final VoidCallback? onAction;
}

/// 错误行动卡（ux-hardening P0-2）：任务中断的白话呈现——标题 + 建议 +
/// 可复制原始异常 + 「重试」动作。区别于 [TrackNote] 的纯通告：本卡携带
/// 自救入口。持久化保留（历史保真）；恢复会话 onAction=null 锁定为不可
/// 重试（恢复的历史里不存在可重跑的任务）。
class TrackError extends TrackEntry {
  TrackError({required this.title, required this.advice, required this.detail});

  final String title;
  final String advice;

  /// 原始异常文本（$error）——排障留痕，可复制。
  final String detail;

  /// 重试回调（null = 锁定态：恢复历史不可重试）。
  VoidCallback? onAction;

  /// 已点过重试 → 锁定为灰阶「已重试」（终态锁定，ui-design §3.2）。
  bool retried = false;
}

/// 记忆胶囊（P2-6 / §3.6）：气泡底「⚡ 已记录 key=value [✕撤销]」嵌片——
/// 模型 In-band 捎带落库后页面插入；撤销回调由页面注入（session 域 →
/// workspace_states.remove），撤销后锁定终态呈现「已撤销」。
/// 恢复的历史胶囊不接撤销回调（onUndo=null 锁定，completer 同口径）。
class TrackMemoryCapsule extends TrackEntry {
  TrackMemoryCapsule({required this.key, required this.value, this.onUndo});

  final String key;
  final String value;

  /// 撤销回调（null = 撤销不可用：已撤销锁定 / 历史恢复态）。
  void Function()? onUndo;
  bool undone = false;
}

/// 本轮上下文归因条目（展示 only）：Run 装配后由页面插入，呈现「本轮携带
/// 哪些上下文」——记忆条目（scope 标签 + 内容）与已挂载服务；历史恢复态
/// 锁定呈现（onItemExclude=null，同 TrackMemoryCapsule 口径）。
/// 「本轮排除」为预留钩子：回调由页面注入才出现 ✕ 按钮，当前不接线，
/// 仅承载未来「排除 → 重新生成」的交互落点。
class ContextAttributionItem {
  const ContextAttributionItem({required this.source, required this.text});

  /// 来源标签（记忆 scope 如 `user` / `srv:goodshare`；服务则为其摘要名）。
  final String source;
  final String text;
}

class TrackContextAttribution extends TrackEntry {
  TrackContextAttribution({
    required this.memories,
    required this.services,
    this.droppedCount = 0,
    this.onItemExclude,
    this.onViewMemories,
  });

  /// 注入本轮 prompt 的记忆快照（原始顺序，页面上限内逐条展示）。
  final List<ContextAttributionItem> memories;

  /// 已挂载服务展示名快照（serverSummaries 值）。
  final List<ContextAttributionItem> services;

  /// 超预算丢弃的记忆条数（0 = 无截断）。
  final int droppedCount;

  /// 预留：单条排除回调（null = 不渲染排除按钮；当前页面不接线）。
  void Function(ContextAttributionItem item)? onItemExclude;

  /// P1-7（2026-10-22）：直接跳 AppBar「本轮记录」汇总面板的回调。
  /// null = 详情仍按旧样逐条列出（历史恢复态同口径：无活页面可跳）。
  /// 动机：同一份记忆曾有三处展示（归因详情 / AppBar 列表 / 流内胶囊），用户
  /// 分辨不出哪一处是「可管理的那份」——此处降级为计数 + 直达入口。
  VoidCallback? onViewMemories;
}

/// elicitation 交互卡（server→宿主结构化提问；MCP 2025-06-18 elicitation/create）。
/// 未决态（answer == null）弹表单；已决态（answer != null）锁定呈现。
class TrackElicitation extends TrackEntry {
  TrackElicitation({required this.request});

  final ElicitationRequest request;

  /// 待决挂起（**惰性**，同 [TrackPlanConfirm.completer] 口径）。
  Completer<ElicitationAnswer>? _completer;
  Completer<ElicitationAnswer> get completer =>
      _completer ??= Completer<ElicitationAnswer>();
  ElicitationAnswer? answer;
  DateTime? decidedAt;
}

// ---------------------------------------------------------------------------
// 序列化（M4-T3b）：TrackEntry ↔ JSON——ConversationStore 只存 JSON。
// S4 下沉 coordinator：内核认识轨道语义，会话持久化不再是 UI 模型序列化。
// 格式字节级不变（既有存档全部可解；格式钉 = track_codec_test +
// chat_track_model_test 字面 pin）。
// ---------------------------------------------------------------------------

extension TrackEntryCodec on TrackEntry {
  static List<Map<String, Object?>> encode(List<TrackEntry> entries) => [
    for (final e in entries) _encode(e),
  ];

  static Map<String, Object?> _encode(TrackEntry e) => switch (e) {
    TrackUser(:final text) => {'type': 'user', 'text': text},
    // 思考轨持久化保留（历史保真）：展开态随存档恢复（缺省 = 收起）。
    TrackThinking e => {
      'type': 'thinking',
      'text': e.text.toString(),
      'expanded': e.expanded,
    },
    TrackText(:final text) => {'type': 'text', 'text': text.toString()},
    TrackCall e => {
      'type': 'call',
      'tool': e.tool,
      'phase': e.phase.name,
      'progressNote': ?e.progressNote,
      'preview': e.preview,
      'resultText': e.resultText,
      // A2：描述全文持久化（恢复会话人话行不丢；缺省 = 旧数据无描述）。
      'description': ?e.description,
    },
    TrackPlanConfirm(
      :final card,
      :final decision,
      :final decidedAt,
      :final lockedSummary,
    ) =>
      {
        // 计划原文归档（goal + 全部步骤行，含读信息行）；决策后为审计态。
        'type': 'plan_confirm',
        'goal': card.goal,
        'rows': [
          for (final r in card.rows)
            {
              'id': r.step.id,
              'server': r.step.server,
              'tool': r.step.tool,
              'intent': r.step.intent,
              'write': r.isWrite,
              if (r.destructive) 'destructive': true,
              'blocked': ?r.blockedReason,
            },
        ],
        'approved': ?decision?.approved,
        'summary': ?lockedSummary ??
            (decision == null ? null : '会话中断于计划确认'),
        'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
      },
    TrackPlanResult(:final record) => {
      'type': 'plan_result',
      'goal': record.goal,
      'status': record.status.name,
      'rows': [
        for (final r in record.rows)
          {
            'id': r.step.id,
            'server': r.step.server,
            'tool': r.step.tool,
            'intent': r.step.intent,
            'note': ?r.step.note,
            'calls': r.calls,
            'ok': r.ok,
            'failed': r.failed,
            'skippedByUser': r.skippedByUser,
            'closedPending': r.closedPending,
          },
      ],
      'outOfBand': [
        for (final e in record.outOfBand.entries)
          {'pair': e.key, 'count': e.value},
      ],
      'echoes': record.echoByStep,
    },
    TrackConfirm(:final pending, :final decision, :final decidedAt) => {
      'type': 'confirm',
      'toolName': pending.toolName,
      'argumentsJson': pending.argumentsJson,
      'approved': ?decision?.approved,
      'reason': ?decision?.reason,
      'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
    },
    TrackBreaker(
      :final report,
      :final wall,
      :final lockedText,
      :final decidedAt,
    ) =>
      {
        'type': report != null ? 'breaker' : 'wall',
        'toolName': ?report?.toolName,
        'consecutiveFailures': ?report?.consecutiveFailures,
        'lastError': ?report?.lastError,
        'argumentsJson': ?report?.argumentsJson,
        'turnsUsed': ?wall?.turnsUsed,
        'limit': ?wall?.limit,
        'lockedText': ?lockedText,
        'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
      },
    TrackFence(:final info, :final decision, :final decidedAt) => {
      'type': 'fence',
      'engineName': info.engineName,
      'failureMessage': info.failureMessage,
      'sendRaw': ?decision,
      'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
    },
    TrackElicitation(:final request, :final answer, :final decidedAt) => {
      'type': 'elicitation',
      'message': request.message,
      'schema': request.schema,
      'action': answer?.accepted == true ? 'accept' : 'decline',
      'content': answer?.content,
      'reason': answer?.reason,
      'decidedAt': ?decidedAt?.millisecondsSinceEpoch,
    },
    TrackNote(:final text, :final danger, :final category) => {
      'type': 'note',
      'text': text,
      'danger': danger,
      'category': category.name,
    },
    // 瞬态条目：页面持久化前已过滤；此处兜底防直插（丢动作保文本）。
    TrackGuide(:final text) => {'type': 'note', 'text': text, 'danger': false},
    // 错误卡持久化保留（历史保真）：onAction 不序列化（恢复态锁定）。
    TrackError e => {
      'type': 'error',
      'title': e.title,
      'advice': e.advice,
      'detail': e.detail,
      'retried': e.retried,
    },
    TrackMemoryCapsule(:final key, :final value, :final undone) => {
      'type': 'memory',
      'key': key,
      'value': value,
      'undone': undone,
    },
    TrackContextAttribution(
      :final memories,
      :final services,
      :final droppedCount,
    ) =>
      {
        'type': 'context',
        'memories': [
          for (final m in memories) {'s': m.source, 't': m.text},
        ],
        'services': [
          for (final s in services) {'s': s.source, 't': s.text},
        ],
        'droppedCount': droppedCount,
      },
  };

  /// 恢复轨道（终态锁定呈现）：
  /// - 进行态卡片（running/stuck）收敛为 cancelled +「会话中断」预览——
  ///   恢复的历史里不存在仍在执行的工具；
  /// - 未决交互卡（confirm/breaker/fence 无裁决）降级为 Rose 通告行「会话
  ///   中断于待决卡片」——严禁恢复成可交互死卡（completer 无人应答）；
  /// - 未知条目降级为通告行（降级铁律：留痕不吞）。
  static List<TrackEntry> decode(List<dynamic> raw) {
    final out = <TrackEntry>[];
    for (final item in raw) {
      if (item is! Map) {
        out.add(const TrackNote('⚠ 存在无法恢复的轨道条目（格式未知）', danger: true, category: TrackNoticeCategory.error));
        continue;
      }
      final m = Map<String, Object?>.from(item);
      final decidedAt = m['decidedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(m['decidedAt'] as int)
          : null;
      switch (m['type']) {
        case 'plan_confirm':
          // 决策审计行（终态）；无决策的历史降级 Rose 通告行。
          final summary = m['summary'] as String?;
          out.add(TrackNote(
            summary ?? '⚠ 计划卡无决策记录（会话中断）',
            danger: summary == null || !(m['approved'] == true),
            category: TrackNoticeCategory.error,
          ));
        case 'plan_result':
          final status = PlanAggregateStatus.values.firstWhere(
            (s) => s.name == m['status'],
            orElse: () => PlanAggregateStatus.failed,
          );
          final rows = <PlanLedgerStepView>[
            for (final raw in (m['rows'] as List? ?? const []))
              if (raw is Map)
                PlanLedgerStepView(
                  step: FrozenPlanStep(
                    id: raw['id'] as String? ?? '',
                    server: raw['server'] as String? ?? '',
                    tool: raw['tool'] as String? ?? '',
                    intent: raw['intent'] as String? ?? '',
                    note: raw['note'] as String?,
                  ),
                  calls: raw['calls'] is int ? raw['calls'] as int : 0,
                  ok: raw['ok'] is int ? raw['ok'] as int : 0,
                  failed: raw['failed'] is int ? raw['failed'] as int : 0,
                  skippedByUser: raw['skippedByUser'] == true,
                  closedPending: raw['closedPending'] == true,
                ),
          ];
          final echoes = <String, String>{
            if (m['echoes'] is Map)
              for (final e in (m['echoes'] as Map).entries)
                if (e.key is String) e.key as String: '${e.value}',
          };
          out.add(TrackPlanResult(
            record: PlanAggregateRecord(
              goal: m['goal'] as String? ?? '',
              status: status,
              rows: rows,
              outOfBand: {
                for (final e in (m['outOfBand'] as List? ?? const []))
                  if (e is Map && e['pair'] is String)
                    e['pair'] as String:
                        e['count'] is int ? e['count'] as int : 0,
              },
              echoByStep: echoes,
            ),
            // onResume 不恢复（历史不可续跑；回调不可序列化）。
          ));
        case 'user':
          out.add(TrackUser(m['text'] as String? ?? ''));
        case 'thinking':
          // 历史恢复思考轨：按存档展开态呈现（缺省收起——默认收起拍板口径）。
          out.add(TrackThinking(m['text'] as String? ?? '')
            ..expanded = m['expanded'] as bool? ?? false);
        case 'text':
          out.add(TrackText(m['text'] as String? ?? ''));
        case 'call':
          final phase = CallCardPhase.values.firstWhere(
            (p) => p.name == m['phase'],
            orElse: () => CallCardPhase.cancelled,
          );
          final settled =
              phase == CallCardPhase.running || phase == CallCardPhase.stuck;
          out.add(
            TrackCall(tool: m['tool'] as String? ?? '?')
              ..phase = settled ? CallCardPhase.cancelled : phase
              ..preview = settled ? '(会话中断)' : (m['preview'] as String? ?? '')
              ..progressNote = m['progressNote'] as String?
              ..resultText = m['resultText'] as String? ?? ''
              ..description = m['description'] as String?,
          );
        case 'note':
          out.add(
            TrackNote(
              m['text'] as String? ?? '',
              danger: m['danger'] as bool? ?? false,
              category: _decodeCategory(m['category'] as String?),
            ),
          );
        case 'error':
          // 恢复的错误卡：onAction=null 锁定（恢复历史里无可重跑的任务），
          // retried 原样保留呈现。
          out.add(
            TrackError(
              title: m['title'] as String? ?? '任务中断',
              advice: m['advice'] as String? ?? '',
              detail: m['detail'] as String? ?? '',
            )..retried = m['retried'] as bool? ?? false,
          );
        case 'memory':
          // 历史恢复胶囊：不接撤销回调（onUndo=null 锁定呈现——恢复态无
          // 活页面的 store 绑定；撤销语义仅限当轮）。
          out.add(
            TrackMemoryCapsule(
              key: m['key'] as String? ?? '?',
              value: m['value'] as String? ?? '',
            )..undone = m['undone'] as bool? ?? false,
          );
        case 'context':
          // 历史恢复归因条：仅展示快照（onItemExclude=null 锁定，同上口径）。
          List<ContextAttributionItem> items(Object? raw) => [
            for (final e in (raw as List? ?? const []))
              if (e is Map)
                ContextAttributionItem(
                  source: e['s'] as String? ?? '?',
                  text: e['t'] as String? ?? '',
                ),
          ];
          out.add(
            TrackContextAttribution(
              memories: items(m['memories']),
              services: items(m['services']),
              droppedCount: m['droppedCount'] as int? ?? 0,
            ),
          );
        case 'confirm':
          final approved = m['approved'] as bool?;
          if (approved == null) {
            out.add(_interruptedNote(m['toolName'] as String? ?? '确认卡'));
            continue;
          }
          out.add(
            TrackConfirm(
                pending: ToolPendingConfirmation(
                  toolName: m['toolName'] as String? ?? '?',
                  argumentsJson: m['argumentsJson'] as String? ?? '{}',
                ),
              )
              ..decision = GateDecision(
                approved: approved,
                reason: m['reason'] as String?,
              )
              ..decidedAt = decidedAt,
          );
        case 'breaker':
          if (m['toolName'] is! String) {
            out.add(const TrackNote('⚠ 会话中断于排查卡', danger: true, category: TrackNoticeCategory.error));
            continue;
          }
          out.add(
            TrackBreaker.breaker(
                BreakerReport(
                  toolName: m['toolName'] as String,
                  consecutiveFailures: m['consecutiveFailures'] as int? ?? 0,
                  lastError: m['lastError'] as String? ?? '',
                  argumentsJson: m['argumentsJson'] as String? ?? '{}',
                ),
              )
              ..lockedText = m['lockedText'] as String?
              ..decidedAt = decidedAt,
          );
        case 'wall':
          out.add(
            TrackBreaker.wall(
                StepWallReport(
                  turnsUsed: m['turnsUsed'] as int? ?? 0,
                  limit: m['limit'] as int? ?? 0,
                ),
              )
              ..lockedText = m['lockedText'] as String?
              ..decidedAt = decidedAt,
          );
        case 'fence':
          final sendRaw = m['sendRaw'] as bool?;
          if (sendRaw == null) {
            out.add(const TrackNote('⚠ 会话中断于围栏拦截卡', danger: true, category: TrackNoticeCategory.error));
            continue;
          }
          out.add(
            TrackFence(
                PiiMaskBlockInfo(
                  engineName: m['engineName'] as String? ?? '?',
                  failureMessage: m['failureMessage'] as String? ?? '',
                  cause: '（历史会话：原始异常不可序列化，恢复期以消息文本为准）',
                ),
              )
              ..decision = sendRaw
              ..decidedAt = decidedAt,
          );
        case 'elicitation':
          final action = m['action'] as String?;
          if (action == null) {
            out.add(_interruptedNote(m['message'] as String? ?? 'elicitation'));
            continue;
          }
          out.add(
            TrackElicitation(
              request: ElicitationRequest(
                message: m['message'] as String? ?? '',
                schema: m['schema'] is Map<String, Object?>
                    ? m['schema'] as Map<String, Object?>
                    : const {},
              ),
            )
              ..answer = action == 'accept'
                  ? ElicitationAnswer(
                      accepted: true,
                      content: m['content'] is Map<String, Object?>
                          ? m['content'] as Map<String, Object?>
                          : const {},
                    )
                  : ElicitationAnswer(accepted: false, reason: m['reason'] as String?),
          );
        default:
          out.add(const TrackNote('⚠ 存在无法恢复的轨道条目（类型未知）', danger: true));
      }
    }
    return out;
  }

  static TrackNote _interruptedNote(String what) =>
      TrackNote('⚠ 会话中断于待决卡片（$what 未裁决）', danger: true, category: TrackNoticeCategory.error);

  /// 恢复存档的 category 还原（兼容旧存档无此字段）：
  /// 有字段按名映射；无字段则按 danger 推断（danger = 错误类内联，否则事实类入账本）。
  static TrackNoticeCategory _decodeCategory(String? name) {
    if (name == null) return TrackNoticeCategory.fact;
    return TrackNoticeCategory.values.firstWhere(
      (c) => c.name == name,
      orElse: () => TrackNoticeCategory.fact,
    );
  }
}

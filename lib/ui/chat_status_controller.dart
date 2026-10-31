/// chat_page 状态与副作用收敛件（window-slim P1-B/C/D 二轮下沉）。
///
/// 把散落在 `ChatPage` 的三类职责收口到一处，与 UI 渲染解耦：
/// - **状态带（B）**：pill 标签/相位、运行态、已耗时起点、自动跟随标志——原页面
///   每改一处即整页 `setState`；现经 `statusListenable` 仅状态带 + 底部输入集群
///   局部重建（[ChatComposer] 经 `ListenableBuilder` 接本端口）；
/// - **轨道列表（B）**：列表结构性变更（增/删/清）经 `tracksListenable` 仅双轨流
///   重建，且各条目内部细粒度刷新由条目自身承担（C：TrackText/TrackCall 自管）；
/// - **副作用（D）**：滚动锚定（pinToBottom/onUserScroll）、键盘遮挡再锚定
///   （didChangeMetrics 回调本件）、会话切换生命周期（resetForSession）。
///
/// 双 `Listenable` 切分是「状态流转/UI 分离」的关键：pill/elapsed 高频变更不牵连
/// 轨道列表重建，轨道新增/删除也不牵连底部输入集群——只有真正相关的子树重绘。
///
/// **流式文本缓冲（stream-perf §3，2026-10-19 下沉）**：delta 经 40ms 节拍批量
/// 刷盘；保序铁律——**任何非文本条目入轨（addEntry）前必须先刷空文本缓冲**。
/// 否则缓冲期内到达的尾帧会被同步入轨的 note/工具卡/错误卡甩到后面（真机实证：
/// 「✓ 任务完成」插到回复正文中间，尾帧「吗？」另起气泡落到标记之后）。
library;

import 'package:flutter/material.dart';
import '../core/notice_category.dart';

import 'components/dual_track_stream.dart';
import 'components/status_capsule.dart';
import 'components/stream_text_buffer.dart';

/// Run 归属令牌（文本气泡的归属键）：由 [ChatStatusController.beginRun] 逐 Run
/// 发号，按值可比、跨会话单调递增。
///
/// 设计要点（2026-10-31 气泡边界修正）：气泡边界由「Run 归属 + 轨道结构」在
/// 状态机内派生，调用方零纪律——跨轮追加在机制上不可能发生。此前靠调用点
/// 手工断流（收尾/起步各补一处），漏调即跨轮气泡黏连（真机「第二轮没有
/// 输出」）；发号权收归状态机后，「恰好每次新建一个 sink 实例」这类隐含
/// 契约不再承担正确性。
@immutable
class ChatRunId {
  const ChatRunId(this.seq);

  /// Run 序号（逐 Run 递增，跨会话不复用）。
  final int seq;

  @override
  bool operator ==(Object other) => other is ChatRunId && other.seq == seq;

  @override
  int get hashCode => seq.hashCode;

  @override
  String toString() => 'run#$seq';
}

class ChatStatusController extends ChangeNotifier {
  ChatStatusController() {
    _streamBuf.onFlush = _onStreamFlush;
  }

  // —— 状态带（statusListenable）—————————————————————————————
  String _pillLabel = 'idle';
  CapsuleTone _pillTone = CapsuleTone.idle;
  bool _running = false;
  DateTime? _runStartedAt;
  bool _autoFollow = true;

  final ChangeNotifier _statusNc = ChangeNotifier();

  /// 状态带变更端口：pill/运行态/已耗时/自动跟随变化 → 仅状态带与输入集群重建。
  Listenable get statusListenable => _statusNc;

  /// 轨道列表结构性变更端口：增/删/清 → 仅双轨流重建（条目内部刷新另走自管）。
  Listenable get tracksListenable => _tracksNc;

  String get pillLabel => _pillLabel;
  CapsuleTone get pillTone => _pillTone;
  bool get running => _running;
  DateTime? get runStartedAt => _runStartedAt;
  bool get autoFollow => _autoFollow;

  void setPill(String label, CapsuleTone tone) {
    if (_pillLabel == label && _pillTone == tone) return;
    _pillLabel = label;
    _pillTone = tone;
    _statusNc.notifyListeners();
  }

  void setRunning(bool v) {
    if (_running == v) return;
    _running = v;
    _statusNc.notifyListeners();
  }

  void setRunStartedAt(DateTime? v) {
    if (_runStartedAt == v) return;
    _runStartedAt = v;
    _statusNc.notifyListeners();
  }

  void setAutoFollow(bool v) {
    if (_autoFollow == v) return;
    _autoFollow = v;
    // 回到自动跟随（用户滚回底部 / 点「回到最新」）即清零未读计数——两件事
    // 同一个语义站位（见 missedSinceDetach）。
    if (_autoFollow) _missedSinceDetach = 0;
    _statusNc.notifyListeners();
  }

  /// 离底期间新增的条目数（P1-10：浮钮计数判别是否有新内容）。
  ///
  /// 语义：用户上翻看历史 = 主动脱离跟随；此后每条入轨的新内容计数 +1，回到
  /// 底部清零。浮钮据此区分「只是翻上去了」与「下面有 N 条没看」——此前同一
  /// 个箭头表达两种含义，用户无法判断是否该点。纯视图态，随会话重置清零。
  int get missedSinceDetach => _missedSinceDetach;
  int _missedSinceDetach = 0;

  /// Run 起步一次性收口：运行态 + connecting 相位 + 已耗时起点 + 恢复自动跟随。
  /// 替代原 `_send` 内 4 行 `setState`，合并为单次通知。
  ///
  /// 返回本次 Run 的**归属令牌**：文本气泡的跨轮边界据此派生（见
  /// [appendStreamText]）——令牌由状态机发号，调用方既不需要也无法手工
  /// 断流（纪律外移即纪律缺失）。
  ChatRunId beginRun({required DateTime startedAt}) {
    final id = ChatRunId(++_runSeq);
    _running = true;
    _pillLabel = 'connecting';
    _pillTone = CapsuleTone.l1;
    // A07（review-fix-2026-10）：直写 _autoFollow 须与 setAutoFollow 同口径——
    // 清未读计数（原残留旧值，离底徽标跨轮累加）。
    _autoFollow = true;
    _missedSinceDetach = 0;
    _runStartedAt = startedAt;
    _statusNc.notifyListeners();
    return id;
  }

  /// Run 发号器（逐 Run 递增，跨会话不复用——切会话不得复用旧令牌）。
  int _runSeq = 0;

  /// Run 收尾：仅落运行态与计时（相位由调用处显式 setPill 决定，如 done/failed）。
  ///
  /// 内建刷盘：Run 边界由状态机收口——收尾时刻的 ≤40ms 缓冲残余立即落地，
  /// 不依赖节拍定时器恰好命中（页面销毁/切会话即丢尾帧的路径由此闭合）。
  void endRun() {
    _streamBuf.flush();
    _running = false;
    _runStartedAt = null;
    _statusNc.notifyListeners();
  }

  // —— 轨道列表（tracksListenable）—————————————————————————————
  final List<TrackEntry> tracks = <TrackEntry>[];
  final ChangeNotifier _tracksNc = ChangeNotifier();

  void addEntry(TrackEntry entry) {
    // 保序铁律（stream-perf §3）：非文本条目入轨前先刷空文本缓冲——delta 走
    // 40ms 节拍，note/工具卡/错误卡/胶囊是同步入轨的，不先刷盘尾帧就会被甩到
    // 条目之后（真机实证：「✓ 任务完成」插到回复正文中间）。
    _streamBuf.flush();
    // 通告按 [TrackNoticeCategory] 三分路由（2026-10-31 后续治理）：错误类回
    // 对话流内联、事实类进账本单槽、过程类不收纳（仅页面瞬态 pill）。口径见
    // [_routeNotice]。
    if (entry is TrackNote) {
      _routeNotice(entry);
      return;
    }
    // 气泡边界派生（2026-10-31 设计修正）：任何入轨的非文本条目 = 阅读流
    // 出现块级打断 → 关闭活动文本段，后续正文另起气泡（顺序恒真）。此前
    // 靠调用点手工 breakTextStream（工具卡处），新增打断条目漏调即正文
    // 渲染到块级条目之前——保序铁律只保「尾帧不被甩后」，不保「不黏连」。
    if (entry is! TrackText) _closeTextSegment();
    tracks.add(entry);
    // P1-10：脱离跟随期间入轨 = 用户还没看到的条目（浮钮据此显示未读计数）。
    if (!_autoFollow) _missedSinceDetach++;
    _tracksNc.notifyListeners();
  }

  /// 本会话轨道是否存在记忆胶囊（悬浮 ≡ 按钮的显隐依据）。
  bool get hasMemoryCapsules => tracks.any((e) => e is TrackMemoryCapsule);

  void addEntries(List<TrackEntry> entries) {
    // A08（review-fix-2026-10）：与 addEntry 同守保序铁律——批量入轨前先刷空
    // 文本缓冲（当前仅恢复快照路径调用故未踩中，属潜伏雷，收口防患）。
    _streamBuf.flush();
    // 还原口径须与在线口径一致（2026-10-31 后续治理）：按 [TrackNoticeCategory]
    // 路由——错误类留阅读轨内联、事实类进账本单槽、过程类丢弃不收纳，否则一
    // 恢复历史会话就退回旧口径刷屏。
    final kept = <TrackEntry>[];
    final factNotes = <TrackNote>[];
    for (final e in entries) {
      if (e is TrackNote) {
        switch (e.category) {
          case TrackNoticeCategory.error:
            kept.add(e); // 错误内联阅读轨
            if (e.danger) _sessionHadDanger = true;
          case TrackNoticeCategory.process:
            // 过程类不收纳：丢弃
          case TrackNoticeCategory.fact:
            factNotes.add(e); // 事实进账本单槽
            if (e.danger) _sessionHadDanger = true;
        }
      } else {
        kept.add(e);
      }
    }
    tracks.addAll(kept);
    // 恢复快照 = 轨道整体替换 → 活动文本段随之关闭（后续 delta 另起气泡）。
    _closeTextSegment();
    for (final n in factNotes) {
      _latestFactNotice = n; // 单槽：仅留最后一条事实
      _factNoticeCount++;
    }
    _tracksNc.notifyListeners();
  }

  void removeWhere(bool Function(TrackEntry) test) {
    tracks.removeWhere(test);
    // 事实类单槽账本同步出账（如临时状态行被显式撤下）：撤下即从未发生过，
    // 不该留在记录里被当成既成事实。
    if (_latestFactNotice != null && test(_latestFactNotice!)) {
      _latestFactNotice = null;
    }
    _tracksNc.notifyListeners();
  }

  // —— 本轮记录：事实类单槽账本（2026-10-31 后续治理）——
  /// 本会话**最新一份**事实类通告——AppBar「本轮记录」面板的数据源。
  ///
  /// 动机（用户拍板 2026-10-31 + 后续治理）：原账本无差别累积全部通告，多轮
  /// 会话里同一条事实（引擎就绪 / 插件挂载 / CoW 重名）反复记账 → 面板刷屏。
  /// 现按语义三分：
  /// - 事实类 → 本单槽账本，**仅留最新一份**（同文案重复轮次覆盖式收敛）；
  /// - 错误类 → 回对话流内联（发生当场可见，不进账本，防被良性事实覆盖吞掉）；
  /// - 过程类 → 不收纳，仅页面瞬态 pill 一闪即过。
  ///
  /// 生命周期 = 会话级（[resetForSession] / [clearTracks] 随轨焚）：本件的定位
  /// 是「本轮/本会话发生了什么」，非跨会话审计（跨会话全局留痕另有 AppLog）。
  TrackNote? _latestFactNotice;

  /// 事实类通告累计发生次数（聚合口径：面板标题展示「共 N 次」，账本本身只存
  /// 最新一份，不丢「发生过几次」的元数据）。
  int _factNoticeCount = 0;

  /// 本会话是否出现过危险通告（事实 / 错误任一）——驱动 AppBar 入口红标与
  /// tooltip（§6 双通道：颜色之外的第二通道）。即便危险错误已内联对话流，红标
  /// 仍须反映「本会话出过问题」。
  bool _sessionHadDanger = false;

  /// 通告快照（只读）：事实类单槽——空或仅含最新一份。
  List<TrackNote> get sessionNotices =>
      _latestFactNotice == null ? const [] : [_latestFactNotice!];

  /// 最新一份事实类通告（面板直接渲染用）。
  TrackNote? get latestFactNotice => _latestFactNotice;

  /// 事实类通告累计次数（记录入口是否强调的判据之一）。
  int get noticeCount => _factNoticeCount;

  /// 本会话是否出现过危险通告（§6 双通道：入口配色之外另有 tooltip/文案明示）。
  bool get hasDangerNotice =>
      _latestFactNotice?.danger == true || _sessionHadDanger;

  /// 通告三分路由（2026-10-31 后续治理）：错误类入阅读轨、事实类进单槽账本、
  /// 过程类不收纳（仅页面层瞬态 pill，本件不存储）。
  void _routeNotice(TrackNote note) {
    switch (note.category) {
      case TrackNoticeCategory.error:
        // 错误回对话流内联：发生当场即见，且不被后到的良性事实覆盖吞掉。
        tracks.add(note);
        if (!_autoFollow) _missedSinceDetach++;
        if (note.danger) _sessionHadDanger = true;
      case TrackNoticeCategory.process:
        // 过程类不收纳：瞬态展示由页面层 _add 拦截转瞬态 pill，本件零存储。
        if (note.danger) _sessionHadDanger = true; // 过程危险仍记告警档（极少）
        return;
      case TrackNoticeCategory.fact:
        // 事实类单槽覆盖式入账：同文案重复轮次只留最新一份。
        _latestFactNotice = note;
        _factNoticeCount++;
        if (note.danger) _sessionHadDanger = true;
    }
    _tracksNc.notifyListeners();
  }

  void clearTracks() {
    if (tracks.isEmpty &&
        _latestFactNotice == null &&
        _factNoticeCount == 0) {
      return;
    }
    tracks.clear();
    _latestFactNotice = null; // 记录随轨焚（同会话轨道一并弃）
    _factNoticeCount = 0;
    _sessionHadDanger = false;
    _tracksNc.notifyListeners();
  }

  /// 会话切换/重置：清轨道 + 复位状态带到 idle + 复位自动跟随（D：生命周期归拢）。
  /// 流控残余先刷盘（落旧轨随 clear 一并弃）——禁直接丢缓冲：节拍定时器迟到
  /// 的 flush 会把旧会话尾帧写进新会话轨道。
  void resetForSession() {
    _streamBuf.flush();
    _activeTextEntry = null;
    _activeTextRun = null; // 归属令牌随会话焚（新会话新令牌，不复用）
    _pendingTextRun = null;
    tracks.clear();
    _latestFactNotice = null; // 事实留痕随会话焚（记录 = 本轮口径）
    _factNoticeCount = 0;
    _sessionHadDanger = false;
    _claimedNotices.clear(); // 会话级通告记账随会话焚（新会话可重告）
    _missedSinceDetach = 0; // 未读计数随会话焚
    _pillLabel = 'idle';
    _pillTone = CapsuleTone.idle;
    _running = false;
    _runStartedAt = null;
    _autoFollow = true;
    _statusNc.notifyListeners();
    _tracksNc.notifyListeners();
  }

  // —— 会话级通告去重（P0-3 降噪，2026-10-22）——————————————————————
  /// 已通告过的主题键集合（同会话内同一语义只通告一次）。
  ///
  /// 动机：每轮必出的重复通告（如「有 N 个服务已卸载」）在多轮会话里逐行堆积，
  /// 吃掉阅读面积。记账属**视图态**（「本会话轨道里是否已说过」），随
  /// [resetForSession] 清账——会话切换/历史恢复即自然重告，零领域态泄漏。
  final Set<String> _claimedNotices = <String>{};

  /// 申领一次通告额度：返回 true = 本会话尚未说过（可入轨）；false = 已说过
  /// （调用方应跳过）。**键须随内容变**（如计数变化）——配置真的变了仍会再告。
  bool claimSessionNotice(String key) => _claimedNotices.add(key);

  // —— 流式文本（stream-perf §3）———————————————————————————
  final _streamBuf = StreamTextBuffer();

  /// 活动文本条目（自管重绘）+ **归属 Run 令牌**（2026-10-31 设计修正）：
  /// 气泡边界由状态机派生——① Run 归属（跨轮必另起气泡）② 轨道结构（块级
  /// 条目入轨即关闭本段）。两条都在机制内，调用方零纪律（此前靠 Run 收尾/
  /// 起步手工 breakTextStream，漏调即跨轮气泡黏连——真机「第二轮没有输出」）。
  TrackText? _activeTextEntry;
  ChatRunId? _activeTextRun;

  /// 刷盘时待归属的 Run 令牌（add 时记账，flush 时判定——40ms 异步节拍下
  /// 跨 Run 边界的缓冲残余必须先落进旧 Run 的条目）。
  ChatRunId? _pendingTextRun;

  /// delta 入池（40ms 节拍批量刷盘）。[run] = 归属 Run 令牌（[beginRun] 发号）。
  /// dispose 后静默丢弃（终态语义）。
  void appendStreamText(String delta, {required ChatRunId run}) {
    if (_pendingTextRun != run && _streamBuf.hasPending) {
      _streamBuf.flush(); // Run 切换：上一 Run 残余先刷进其条目，保序
    }
    _pendingTextRun = run;
    _streamBuf.add(delta);
  }

  /// 强制刷盘（Run 收尾/中止/异常三路径 + 快照读路径）：残余立即落地。
  void flushStreamText() => _streamBuf.flush();

  /// 关闭活动文本段（下一段正文另起气泡）：块级条目入轨即调用——文本段
  /// 边界由轨道结构派生，调用方无须（也无法）手工断流。
  void _closeTextSegment() => _activeTextEntry = null;

  /// 轨道快照读取（读即刷盘）：任何要落盘/编码轨道视图的路径都经此取值，
  /// 尾帧必在快照内——Run 收尾 ≤40ms 残余不再随定时器命中与否而丢。
  List<TrackEntry> get flushedTracks {
    _streamBuf.flush();
    return List<TrackEntry>.unmodifiable(tracks);
  }

  /// 刷盘回调（缓冲装配期一次性设置）：归属 Run 令牌与活动条目不符 = 跨 Run
  /// 边界 → 自动另起气泡（状态机内建，调用方零纪律）；同 Run 续接（仅自身
  /// 重绘），无条目则新建并入轨（结构性新增 → tracksListenable 通知）。
  void _onStreamFlush(String text) {
    final run = _pendingTextRun;
    if (_activeTextRun != run) {
      _activeTextEntry = null;
      _activeTextRun = run;
    }
    final active = _activeTextEntry;
    if (active != null) {
      active.append(text);
    } else {
      _activeTextEntry = TrackText(text);
      addEntry(_activeTextEntry!); // 缓冲已在 drain 后为空，无重入递归
    }
    pinToBottom();
  }

  // —— 滚动锚定 / 键盘（D）———————————————————————————————————
  ScrollController? _scrollCtrl;

  /// 注入滚动控制器（页面持有生命周期，仅把锚定逻辑收口本件）；传 null 即解绑。
  void attachScroll(ScrollController? c) => _scrollCtrl = c;

  /// 用户滚动监听：离开底部即暂停自动跟随（流式输出不劫持滚动），回到
  /// 底部恢复。程序性 jumpTo 恒落底部，不会误触该标志。
  void onUserScroll() {
    final c = _scrollCtrl;
    if (c == null || !c.hasClients) return;
    final atBottom = c.position.pixels >= c.position.maxScrollExtent - 24;
    if (atBottom != _autoFollow) setAutoFollow(atBottom);
  }

  /// 自动跟随时拽回底部（post-frame，避免构建期访问 layout）。键盘升降经
  /// `WidgetsBinding.didChangeMetrics` 回调本方法再锚定（D：键盘遮挡收敛）。
  void pinToBottom() {
    if (!_autoFollow) return; // 用户上翻看历史中：不拽回
    final c = _scrollCtrl;
    if (c == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.hasClients) {
        c.jumpTo(c.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _streamBuf.dispose(); // 取消节拍定时器（widget 已销毁，残余无处可刷）
    _statusNc.dispose();
    _tracksNc.dispose();
    _scrollCtrl = null;
    super.dispose();
  }
}

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

import 'components/dual_track_stream.dart';
import 'components/status_capsule.dart';
import 'components/stream_text_buffer.dart';

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
  void beginRun({required DateTime startedAt}) {
    _running = true;
    _pillLabel = 'connecting';
    _pillTone = CapsuleTone.l1;
    _autoFollow = true;
    _runStartedAt = startedAt;
    _statusNc.notifyListeners();
  }

  /// Run 收尾：仅落运行态与计时（相位由调用处显式 setPill 决定，如 done/failed）。
  void endRun() {
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
    tracks.add(entry);
    // P1-10：脱离跟随期间入轨 = 用户还没看到的条目（浮钮据此显示未读计数）。
    if (!_autoFollow) _missedSinceDetach++;
    _tracksNc.notifyListeners();
  }

  /// 本会话轨道是否存在记忆胶囊（悬浮 ≡ 按钮的显隐依据）。
  bool get hasMemoryCapsules => tracks.any((e) => e is TrackMemoryCapsule);

  void addEntries(List<TrackEntry> entries) {
    tracks.addAll(entries);
    _tracksNc.notifyListeners();
  }

  void removeWhere(bool Function(TrackEntry) test) {
    tracks.removeWhere(test);
    _tracksNc.notifyListeners();
  }

  void clearTracks() {
    if (tracks.isEmpty) return;
    tracks.clear();
    _tracksNc.notifyListeners();
  }

  /// 会话切换/重置：清轨道 + 复位状态带到 idle + 复位自动跟随（D：生命周期归拢）。
  /// 流控残余先刷盘（落旧轨随 clear 一并弃）——禁直接丢缓冲：节拍定时器迟到
  /// 的 flush 会把旧会话尾帧写进新会话轨道。
  void resetForSession() {
    _streamBuf.flush();
    _activeTextEntry = null;
    tracks.clear();
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

  /// 活动文本条目（自管重绘）；null = 文本流中断（工具卡/会话边界），下一段
  /// 文本另起气泡。
  TrackText? _activeTextEntry;

  /// delta 入池（40ms 节拍批量刷盘）。dispose 后静默丢弃（终态语义）。
  void appendStreamText(String delta) => _streamBuf.add(delta);

  /// 强制刷盘（Run 收尾/中止/异常三路径）：取消节拍，残余立即落地。
  void flushStreamText() => _streamBuf.flush();

  /// 文本流中断（工具卡插入 / Run 收尾）：先刷盘残余保序，再断活动条目——
  /// 已入轨文本不被后续条目重排，后续文本另起气泡。
  void breakTextStream() {
    _streamBuf.flush();
    _activeTextEntry = null;
  }

  /// 刷盘回调（缓冲装配期一次性设置）：有活动条目则续接（仅自身重绘），
  /// 无则新建并入轨（结构性新增 → tracksListenable 通知）。
  void _onStreamFlush(String text) {
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

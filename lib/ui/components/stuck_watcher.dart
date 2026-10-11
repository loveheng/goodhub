/// D4 卡死判定（M3-T2，取值拍板 2026-10-11）：双档——有 progress 通道按
/// 「最近 progress 帧」30s 计时；无通道工具按总时长 120s 兜底。疑似卡死
/// 只提示不自动中止（写操作半程悬挂，architecture §10）；心跳帧（SSE
/// comment）不作推进证据（D2 正交语义）。
///
/// sampling 反向请求在途（宿主处理服务端请求中）顺延判定——工具等的是宿主
/// 自己的 LLM，宿主可知状态，30s 口径会误报（T1 评审问答结论，宿主侧感知
/// 即可无需协议变更）。纯 Dart 无 Flutter 依赖，[StuckWatcher.progressStall]
/// 可注入短时长供 fake_async 单测。
library;

import 'dart:async';

class StuckWatcher {
  StuckWatcher({
    this.progressStall = const Duration(seconds: 30),
    this.totalCap = const Duration(seconds: 120),
    required this.onStuck,
  });

  /// progress 通道无更新判卡死的等待窗口（D4：30s）。
  final Duration progressStall;

  /// 无通道工具的总时长兜底（D4：120s）。
  final Duration totalCap;

  /// 判定触发（每工具至多一次）。
  final void Function() onStuck;

  Timer? _stallTimer;
  Timer? _totalTimer;
  bool _hasProgressFrame = false;
  bool _stuck = false;
  int _samplingInFlight = 0;

  bool get isStuck => _stuck;

  /// 工具 Started：双计时启动（progress 等待 30s + 总时长 120s）。
  void start() {
    stop();
    _stallTimer = Timer(progressStall, _onStallTick);
    _totalTimer = Timer(totalCap, _fireStuck);
  }

  /// progress 帧到达：切「有通道」口径——每帧重置 30s 等待（总时长兜底不变）。
  void onProgressFrame() {
    _hasProgressFrame = true;
    if (_stuck) return;
    _stallTimer?.cancel();
    _stallTimer = Timer(progressStall, _onStallTick);
  }

  void _onStallTick() {
    if (_stuck) return;
    if (_samplingInFlight > 0) {
      // sampling 在途：顺延一个窗口再判（宿主推理期间无 progress 属预期）
      _stallTimer = Timer(progressStall, _onStallTick);
      return;
    }
    if (!_hasProgressFrame) return; // 无通道：交给 totalCap 兜底（D4 双档）
    _fireStuck();
  }

  void _fireStuck() {
    if (_stuck) return;
    if (_samplingInFlight > 0) {
      // 总时长兜底同样顺延（sampling 等待期不算「无更新」）
      _totalTimer = Timer(progressStall, _fireStuck);
      return;
    }
    _stuck = true;
    onStuck();
  }

  /// sampling 反向请求开始（宿主处理服务端请求的可知窗口入口）。
  void samplingBegin() => _samplingInFlight++;

  /// sampling 反向请求结束。
  void samplingEnd() {
    if (_samplingInFlight > 0) _samplingInFlight--;
  }

  /// 工具 Finished / Abort / 会话收尾：全停并复位（幂等）。
  void stop() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _totalTimer?.cancel();
    _totalTimer = null;
    _hasProgressFrame = false;
    _stuck = false;
    _samplingInFlight = 0;
  }
}

import '../../coordinator/fenced_cloud_engine.dart'
    show PiiFenceDelegate, PiiMaskBlockInfo;
import '../../coordinator/permission_gateway.dart'
    show GateDelegate, ToolPendingConfirmation, GateDecision;
import '../../coordinator/tool_breaker.dart'
    show BlockDelegate, BreakerReport, StepWallReport, BreakerResolution;
import '../../mcp/elicitation.dart'
    show ElicitationDelegate, ElicitationRequest, ElicitationAnswer;

import 'dual_track_stream.dart';
import 'status_capsule.dart';

/// 轨道写回接口（断点③ step2-3）：delegate 抽离 chat_page 后，经本接口而非
/// 私有 `_state` 访问页面轨道（规避跨文件私有访问 + 反向边）。`_ChatPageState`
/// 实现本接口，把 public 适配到既有私有 `_add`/`_setPill`。
abstract class ChatTrackSink {
  void addTrack(TrackEntry entry);
  void setPill(String label, CapsuleTone tone);
}

/// L2 确认卡委托：轨道插待决卡并 await 用户操作（§10 结算流）。
class ChatGateDelegate implements GateDelegate {
  ChatGateDelegate(this.host);
  final ChatTrackSink host;

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) {
    final entry = TrackConfirm(pending: pending);
    host.addTrack(entry);
    return entry.completer.future;
  }
}

/// 熔断/步数墙排查卡委托。
class ChatBlockDelegate implements BlockDelegate {
  ChatBlockDelegate(this.host);
  final ChatTrackSink host;

  @override
  Future<BreakerResolution> onBreakerTripped(BreakerReport report) {
    host.setPill('breaker', CapsuleTone.danger);
    final entry = TrackBreaker.breaker(report);
    host.addTrack(entry);
    return entry.completer.future.then((value) => value as BreakerResolution);
  }

  @override
  Future<bool> onStepWallReached(StepWallReport report) {
    final entry = TrackBreaker.wall(report);
    host.addTrack(entry);
    return entry.completer.future.then((value) => value as bool);
  }
}

/// N7 围栏拦截确认委托（D4 有人值守面）。
class ChatFenceDelegate implements PiiFenceDelegate {
  ChatFenceDelegate(this.host);
  final ChatTrackSink host;

  @override
  Future<bool> onMaskBlocked(PiiMaskBlockInfo info) {
    host.setPill('fence', CapsuleTone.danger);
    final entry = TrackFence(info);
    host.addTrack(entry);
    return entry.completer.future;
  }
}

/// elicitation 交互卡委托（MCP 2025-06-18 server→宿主结构化提问）：轨道插待决卡
/// 并 await 用户填表，用户操作即 completion（与 ChatGateDelegate 同口径）。
class ChatElicitationDelegate implements ElicitationDelegate {
  ChatElicitationDelegate(this.host);
  final ChatTrackSink host;

  @override
  Future<ElicitationAnswer> request(ElicitationRequest req) {
    final entry = TrackElicitation(request: req);
    host.addTrack(entry);
    return entry.completer.future;
  }
}

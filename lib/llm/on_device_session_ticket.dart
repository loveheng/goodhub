import 'on_device_engine.dart';

/// 会话票据（M1 Expand；设计 SSOT =
/// `docs/design/on-device-lifecycle-single-source.md` §2.2）。
///
/// `:engine` 每次状态变更签发一张，主进程只持「最近见证的票据」——取代散落
/// 布尔量的状态单源化对账载体。
///
/// **epoch = `(instanceId, seq)` 复合键、不做磁盘持久化**：`instanceId` 是
/// `:engine` 进程启动时生成的 UUID（进程重建必变），`seq` 为实例内代次
/// （装载受理/驱逐/释放均 +1）。端侧被 LMK/OEM 强杀时页缓存不可信，持久化
/// 计数器是伪保证；复合键零 IO 且天然表达「进程已重建」。
class SessionTicket {
  const SessionTicket({
    required this.instanceId,
    required this.seq,
    required this.status,
    this.modelId = '',
    this.runtime = '',
    this.issuedAtMs = 0,
  });

  /// 与 Kotlin `engine/SessionTicket.kt` 常量同名同义（跨端键名唯一事实源）。
  static const String kInstanceId = 'instanceId';
  static const String kSeq = 'seq';
  static const String kStatus = 'status';
  static const String kModelId = 'modelId';
  static const String kRuntime = 'runtime';
  static const String kIssuedAtMs = 'issuedAtMs';

  final String instanceId;
  final int seq;
  final EngineStatus status;
  final String modelId;
  final String runtime;
  final int issuedAtMs;

  /// 通道解析（Bundle → `Map<dynamic, dynamic>`）：缺字段 / 空实例标识 → null
  /// （解析失败不静默造票据——造出来就是新的说谎源）。
  static SessionTicket? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final instanceId = raw[kInstanceId];
    final seq = raw[kSeq];
    final ordinal = raw[kStatus];
    if (instanceId is! String || instanceId.isEmpty) return null;
    if (seq is! num || ordinal is! num) return null;
    return SessionTicket(
      instanceId: instanceId,
      seq: seq.toInt(),
      status: engineStatusFromOrdinal(ordinal.toInt()),
      modelId: raw[kModelId] as String? ?? '',
      runtime: raw[kRuntime] as String? ?? '',
      issuedAtMs: (raw[kIssuedAtMs] as num?)?.toInt() ?? 0,
    );
  }

  /// 同实例同代次 = 同一会话（进程重建 `instanceId` 必变，无需跨进程单调）。
  bool sameEpoch(SessionTicket? other) =>
      other != null && instanceId == other.instanceId && seq == other.seq;

  @override
  String toString() => 'SessionTicket($instanceId#$seq status=${status.name} '
      'modelId=$modelId runtime=$runtime)';
}

/// 票据镜像（M1：**只见证 / 作废，不参与判定**）。
///
/// M2 起由它派生 unloaded/loading/ready/failed；M1 阶段仅承载影子对账的
/// 见证面——先让「权威 vs 投影」的漂移可见、可统计，再谈切换判定。
class SessionMirror {
  SessionTicket? ticket;

  void witness(SessionTicket? t) => ticket = t;

  /// 作废 = 置为**未知**（禁止猜测为某个具体态——打地鼠的机制解药，设计 §2.4）。
  void invalidate() => ticket = null;
}

/// 影子对账判据（纯函数，M1 唯一的新增判定面）：返回漂移描述，null = 一致。
///
/// 覆盖两类真实事故形态：① 主进程说 ready 而 `:engine` 非就绪（说谎态，
/// 2026-10-31 实证）；② 主进程非 ready 而 `:engine` 已就绪（漏状态）。
/// 取不到票据（通道异常）**不算状态漂移**——那是另一条失效面，由调用方留痕。
String? sessionMirrorDrift(SessionTicket? remote, OnDeviceLoadState local) {
  if (remote == null) return null;
  final remoteUsable =
      remote.status == EngineStatus.ready || remote.status == EngineStatus.busy;
  if (local == OnDeviceLoadState.ready && !remoteUsable) {
    return '主进程 ready 而 :engine=${remote.status.name}（说谎态）';
  }
  if (local != OnDeviceLoadState.ready && remoteUsable) {
    return '主进程 ${local.name} 而 :engine=${remote.status.name}（漏状态）';
  }
  return null;
}

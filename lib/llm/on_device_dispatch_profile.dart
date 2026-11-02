import 'dart:convert';

/// DispatchProfile 准入画像（2026-11-01 拍板：准入探针与坏后端记忆合并）。
///
/// 设计 SSOT：`docs/design/on-device-admission-probe.md` §1——键 =
/// `<modelId>#<Build.FINGERPRINT>`，值 = 双后端 verdict 同体（NPU/GPU 必须同时
/// 承载，禁只写单条）。落盘 = 模型目录内 `.admission.json`（与 `.asset-meta.json`
/// 同目录，严禁 cacheDir）；文件内自含 `driverFingerprint`，读取时与当前指纹
/// 比对（漂移 = 画像整体失效）。
///
/// 两个写入方共享：① 导入后准入探针（`HEALTHY` + ttft/mem 实测）；
/// ② 运行时崩溃/零产出（标 `EXCLUDED` + reason）——消费方（Dart 路由查表）
/// 查表即决策，不再让 `:engine` 死一次确认坏后端。
enum BackendVerdict { healthy, excluded, error }

/// reason 词表（设计稿 §1 取值集，新增须先扩表）。
enum BackendReason {
  none,
  timeout,
  opNotSupported,
  zeroOutput,
  crash,
  driverIncompatible;

  static BackendReason fromName(String? name) => BackendReason.values
      .firstWhere((e) => e.name == name, orElse: () => BackendReason.none);
}

/// 单后端画像条目。
class BackendProfile {
  const BackendProfile({
    required this.verdict,
    this.reason = BackendReason.none,
    this.ttftMs,
    this.memBytes,
    this.probedAtMs,
  });

  final BackendVerdict verdict;
  final BackendReason reason;
  final int? ttftMs;
  final int? memBytes;
  final int? probedAtMs;

  Map<String, dynamic> toJson() => {
        'verdict': verdict.name,
        if (reason != BackendReason.none) 'reason': reason.name,
        if (ttftMs != null) 'ttftMs': ttftMs,
        if (memBytes != null) 'memBytes': memBytes,
        if (probedAtMs != null) 'probedAt': probedAtMs,
      };

  static BackendProfile fromJson(Map<String, dynamic> json) => BackendProfile(
        verdict: BackendVerdict.values.firstWhere(
          (e) => e.name == json['verdict'],
          orElse: () => BackendVerdict.error,
        ),
        reason: BackendReason.fromName(json['reason'] as String?),
        ttftMs: (json['ttftMs'] as num?)?.toInt(),
        memBytes: (json['memBytes'] as num?)?.toInt(),
        probedAtMs: (json['probedAt'] as num?)?.toInt(),
      );
}

/// 一份模型的完整调度画像（NPU + GPU 双条目）。
class DispatchProfile {
  const DispatchProfile({
    required this.driverFingerprint,
    required this.backends,
    this.probedAtMs,
  });

  /// 写入时的驱动指纹（读取时漂移 = 画像失效）。
  final String driverFingerprint;
  final Map<String, BackendProfile> backends;
  final int? probedAtMs;

  /// 路由查表语义（设计稿 §6）：NPU 健康 → 首选 NPU；NPU 排除 → GPU 条目
  /// 健康 → 直落 GPU；GPU **未探**（条目缺失，如首发探针只探到 NPU）→ 仍返回
  /// GPU（未知 ≠ 已知坏——让既有 NPU→GPU→云降级链自行试，不冤枉切云）；
  /// GPU 排除/报错 → null = 切云。返回目标后端名（'NPU' / 'GPU'），null = 切云。
  String? routeTarget() {
    final npu = backends['NPU'];
    final gpu = backends['GPU'];
    if (npu?.verdict == BackendVerdict.healthy) return 'NPU';
    if (gpu == null || gpu.verdict == BackendVerdict.healthy) return 'GPU';
    return null;
  }

  Map<String, dynamic> toJson() => {
        'probedAt': probedAtMs,
        'driverFingerprint': driverFingerprint,
        'backends': {
          for (final e in backends.entries) e.key: e.value.toJson(),
        },
      };

  static DispatchProfile? fromJson(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final fp = json['driverFingerprint'] as String?;
      final backendsJson = json['backends'] as Map<String, dynamic>?;
      if (fp == null || fp.isEmpty || backendsJson == null) return null;
      return DispatchProfile(
        driverFingerprint: fp,
        probedAtMs: (json['probedAt'] as num?)?.toInt(),
        backends: {
          for (final e in backendsJson.entries)
            if (e.value is Map<String, dynamic>)
              e.key: BackendProfile.fromJson(e.value as Map<String, dynamic>),
        },
      );
    } catch (_) {
      return null; // 损坏画像 = 视为缺失（脏数据不阻断路由）
    }
  }
}

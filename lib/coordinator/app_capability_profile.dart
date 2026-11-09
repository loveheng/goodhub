/// 处理模型 L2：调用方能力档案注册表（ai-capability-export M-C，设计稿 §4）。
///
/// `ai/complete` 受理链的**唯一裁决点**（per-caller 一条档案）：
/// - **identity**：callerKey = 调用方包名（K17 同源物理主键）+ 信任档
///   （复用 thirdconnect 信任分级，零新增身份体系）；
/// - **capabilityScope**：允许的原语集（v1 仅 `ai/complete`）——缺席 = 拒绝；
///   违规冻结即撤销 scope（白名单制 default-deny）；
/// - **rateLimit**：per-caller [SupplyQuota]（默认从严：并发 1 / 频次
///   20 次·60min；同签名生态放宽并发 2——§4.1 分档）；
/// - **lifecyclePolicy**：已信任第三方仅前台调用（[CallerForegroundProbe]
///   探针 null = 未知放行——未知 ≠ 已知有害，DeviceTierGate 同款口径）；
/// - **qosPriority**：外部任务恒低于宿主自用（M-B 已在受理链落 QoS 抢占）；
/// - **audit**：受理/路由/拒绝全记 ops.log（受理链 [AiAuditSink] 恒开）；
/// - **违规冻结（§5 安全防火墙）**：同一调用方连续触发 3 次内容违规 →
///   冻结 AI 借用权限（scope 撤销，受理段 `UNAUTHORIZED`），冻结集合持久化
///   （SharedPreferences，防杀进程刷新），用户面板可解冻（[unfreeze]）。
///
/// 红线：裁决逻辑住宿主（SDK 住调用方进程不可信，§6.2 信任方向红线）；
/// 冻结判定单源 = 本注册表（禁受理链第二份计数）。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'supply_quota.dart';

/// 信任档（设计稿 §4.1 三档；映射 thirdconnect 既有信任分级）。
enum AiTrustTier {
  /// 同签名生态（goodshare 等私有插件）：零弹窗，并发 2，后台放行。
  sameSignature,

  /// 已信任第三方（信任卡白名单）：首次信任卡，并发 1，仅前台调用。
  trustedThirdParty,

  /// 远程网关会话（PC / 跨设备 Bearer）：L1/L2 卡片链，会话级既有背压。
  remoteSession,
}

/// 违规冻结阈值（§5：连续 3 次撤销 capabilityScope）。
const int kAiViolationFreezeThreshold = 3;

/// 冻结集合持久化键（SharedPreferences；重启不清——冻结是治理终态非防滥用
/// 内存态，用户面板显式解冻才恢复）。
const String kPrefAiFrozenCallers = 'ai_export.frozen_callers';

/// 调用方前台探针（lifecyclePolicy 承载）：返回 true=前台 / false=后台 /
/// null=未知（放行 + [DEGRADE] 留痕由装配侧记）。生产实现待
/// PACKAGE_USAGE_STATS 特权接通（UsageStatsManager.getUidImportance）——
/// v1 未接线 = null 放行，诚实降级非静默放行（能力缺失非伪造裁决）。
typedef CallerForegroundProbe = Future<bool?> Function(String callerKey);

/// per-caller 能力档案（注册表惰性建档，进程内单例持有）。
class AppCapabilityProfile {
  AppCapabilityProfile._(this.callerKey, this.tier) {
    quota = SupplyQuota(
      // §4.1 分档：同签名生态并发 2；其余从严并发 1。
      maxConcurrent: tier == AiTrustTier.sameSignature ? 2 : 1,
      callerKey: callerKey,
    );
  }

  /// 调用方身份键（包名；与平台侧死亡事件键同源，K17）。
  final String callerKey;

  /// 信任档（建档即定；升级重建档由注册表 [AppCapabilityRegistry.retier]）。
  AiTrustTier tier;

  /// per-caller 限流（K22 事务语义，随档位并发上限；retier 换档重建）。
  late SupplyQuota quota;

  /// lifecyclePolicy：仅前台调用（已信任第三方档缺省 true）。
  bool get requiresForeground => tier == AiTrustTier.trustedThirdParty;

  /// capabilityScope 撤销（违规冻结；v1 scope 全集只有 ai/complete）。
  bool revoked = false;

  /// 连续违规计数（受理成功即复位——「连续触发」语义）。
  int violations = 0;
}

/// 调用方能力档案注册表（进程级单例；受理链唯一裁决点）。
class AppCapabilityRegistry {
  AppCapabilityRegistry({this.isSameSignature}) {
    // 装配构造即共享（受理链与治理面板用同一实例——UI 解冻必须命中受理链
    // 的内存冻结态，新实例只改 prefs 不改档案内存态即「解冻后仍被拒」假象）。
    _shared ??= this;
  }

  static AppCapabilityRegistry? _shared;

  /// 共享实例（装配未发生时惰性建档；UI 治理面经此解冻）。
  static AppCapabilityRegistry get instance => _shared ??= AppCapabilityRegistry();

  /// 同签名判定钩子（装配注入：宿主签名比对结果；null = 全按第三方从严档）。
  final bool Function(String callerKey)? isSameSignature;

  final Map<String, AppCapabilityProfile> _profiles = {};

  /// 惰性建档：已冻结 callerKey 建档即恢复冻结态（跨重启治理连续性）。
  Future<AppCapabilityProfile> profileFor(String callerKey) async {
    final existing = _profiles[callerKey];
    if (existing != null) return existing;
    final tier = isSameSignature?.call(callerKey) ?? false
        ? AiTrustTier.sameSignature
        : AiTrustTier.trustedThirdParty;
    final p = AppCapabilityProfile._(callerKey, tier);
    if ((await _loadFrozen()).contains(callerKey)) p.revoked = true;
    _profiles[callerKey] = p;
    return p;
  }

  /// 受理 gate：冻结 = scope 撤销 → `UNAUTHORIZED`（含解冻指引话术）。
  bool isRevoked(String callerKey) =>
      _profiles[callerKey]?.revoked ?? false;

  /// 违规上报（内容围栏/云端违规分类命中时由受理链调用）：连续计数满阈值
  /// → 冻结 + 持久化。返回 true = 本次触发冻结。
  Future<bool> reportViolation(String callerKey, String reason) async {
    final p = await profileFor(callerKey);
    if (p.revoked) return false; // 已冻结不再累计
    p.violations++;
    debugPrint('[AI-CAP] violation caller=$callerKey count=${p.violations} reason=$reason');
    if (p.violations < kAiViolationFreezeThreshold) return false;
    p.revoked = true;
    await _persistFrozen(p.callerKey, add: true);
    debugPrint('[AI-CAP] capability frozen caller=$callerKey '
        '($kAiViolationFreezeThreshold strikes) — scope 撤销，用户面板可解冻');
    return true;
  }

  /// 受理成功复位连续违规计数（「连续触发」语义的另一半）。
  void resetViolations(String callerKey) =>
      _profiles[callerKey]?.violations = 0;

  /// 用户面板解冻（治理终态的人工出口；计数归零 + 持久化移除）。
  Future<void> unfreeze(String callerKey) async {
    final p = _profiles[callerKey];
    if (p != null) {
      p.revoked = false;
      p.violations = 0;
    }
    await _persistFrozen(callerKey, add: false);
  }

  // ---- 持久化（冻结集合 StringList；读写失败 DEGRADE 留痕不阻断受理）----

  final Set<String> _frozenCache = {};

  Future<Set<String>> _loadFrozen() async {
    if (_frozenCache.isNotEmpty) return _frozenCache;
    try {
      final prefs = await SharedPreferences.getInstance();
      _frozenCache
        ..clear()
        ..addAll(prefs.getStringList(kPrefAiFrozenCallers) ?? const <String>[]);
    } on Object catch (e) {
      debugPrint('[DEGRADE] ai-capability frozen load: $e');
    }
    return _frozenCache;
  }

  Future<void> _persistFrozen(String callerKey, {required bool add}) async {
    if (add) {
      _frozenCache.add(callerKey);
    } else {
      _frozenCache.remove(callerKey);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(kPrefAiFrozenCallers, _frozenCache.toList());
    } on Object catch (e) {
      debugPrint('[DEGRADE] ai-capability frozen persist: $e');
    }
  }

  /// 信任档重定（装配侧身份判定更新时；档位变化重建配额档）。
  void retier(String callerKey, AiTrustTier tier) {
    final p = _profiles[callerKey];
    if (p == null || p.tier == tier) return;
    p.tier = tier;
    p.quota = SupplyQuota(
      maxConcurrent: tier == AiTrustTier.sameSignature ? 2 : 1,
      callerKey: callerKey,
    );
  }

  /// 测试隔离（生产禁调）。
  void resetForTest() {
    _profiles.clear();
    _frozenCache.clear();
  }
}

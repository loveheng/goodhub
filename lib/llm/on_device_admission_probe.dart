import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import 'device_tier.dart';
import 'llm.dart';
import 'on_device_asset_manager.dart';
import 'on_device_dispatch_profile.dart';
import 'on_device_engine.dart';
import 'on_device_engine_adapter.dart';
import 'on_device_engine_aidl.dart';
import 'on_device_engine_binding.dart';
import 'on_device_model_catalog.dart';
import 'on_device_user_demand.dart';

/// 端侧准入探针编排（DispatchProfile 设计稿 §3/§4，2026-11-01 拍板）。
///
/// 把「运行时故障检测」前移为「导入时准入审核」：模型落盘后、用户会话前，
/// 用一次**真生成微基准**（`"hi"` + maxTokens=8 + 硬超时）固化该模型在本机
/// （按驱动指纹）的调度画像到 `.admission.json`。后续装载决策查表分流，
/// 不再让 `:engine` 死一次确认坏后端（§6）。
///
/// 边界（2026-11-02 实装口径）：
/// - Dart 面无后端选择权（litertlm 的 NPU/GPU 由 `:engine` Runner 内部裁决，
///   GenieX 恒 NPU）——「NPU 败再探 GPU」需 AIDL 增 backend 参数，本轮未做；
///   画像只记录**观测到的实际后端**（票据 runtime 字段映射 NPU/GPU），GPU
///   条目缺失 ≠ 排除（`routeTarget` 语义：未知交既有降级链自试）。
/// - 触发门禁 = `DeviceTierGate.check` 全过（含充电/温控 advisory 面），
///   后台时序（空闲/充电态调度）由调用方编排，本件不做时序假设。
class AdmissionProbe {
  AdmissionProbe({
    required this.onLoad,
    required this.onUnload,
    required this.onGenerate,
    required this.onObservedRuntime,
    required this.onDeviceProbe,
    required this.assetManager,
    this.isEngineBusy,
    this.onFact,
    this.hardTimeout = const Duration(seconds: 10),
    this.probeMaxTokens = 32,
    this.now,
  });

  /// 装载目标模型（复用显式 enable 链，含资产校验）；false = 装载失败。
  /// [backendHint] = 后端选择权注入（AIDL 2026-11-02 #8：'gpu' = 强制 GPU 档
  /// 装载，探针第二段专用）；null = Runner 自裁。
  final Future<bool> Function(OnDeviceModelOption model, String? backendHint)
      onLoad;
  /// 探针后驱逐（§4.5：不常驻，省 ~1.9GB 权重内存）。
  final Future<void> Function() onUnload;
  /// 微基准生成流（prompt = 消息序列 JSON，与主链路同构）。
  final Stream<String> Function(String prompt, {required int maxTokens})
      onGenerate;
  /// 观测后端（票据 runtime 字段；null = 未知，归 GPU 条目缺省）。
  final Future<String?> Function() onObservedRuntime;
  /// 设备环境探针（门禁数据源，§3 设备门禁）。
  final Future<DeviceProbe?> Function() onDeviceProbe;
  final OnDeviceAssetManager assetManager;

  /// 引擎装载链占用判定（W1-2 让位：true = 用户请求在途，探针 load 前止步）。
  /// 生产装配 = `loadState == loading`；null = 未接线（跳过止步检查）。
  final bool Function()? isEngineBusy;

  /// 事实留痕通道（fail-open 显性化）：门禁判定链异常按可用放行时回调一条
  /// fact（默认 null = 静默）。生产装配接 [AppLog]，让「端侧为何异常变慢」
  /// 的真实原因（探针失败放行）可在日志页可查，而非零感知。
  final void Function(String message)? onFact;

  final Duration hardTimeout;

  /// 冒烟生成上限（§4.1 生产探针：≥8 抓 mid-sequence 假绿，32 留复读环
  /// 判定余量——退化输出需跑出 12+ 字符重复尾才定谳）。
  final int probeMaxTokens;
  final DateTime Function()? now;

  /// 探针输入（§4.1 生产探针升格 2026-11-03）：内容承载型中文短问——比
  /// 裸 "hi" 更抓模板配错面（模板错 → 复读/退化形态输出，12222 真机事故
  /// 同源），同 messages JSON 契约走 SDK 模板路径；maxTokens 默认 32 抓
  /// mid-sequence Softmax 溢出 / FastRPC 超时（1-token 会假绿）。
  static const String probePromptJson =
      '[{"role":"user","content":"请用一句话介绍你自己。"}]';

  /// 复读环判定（冒烟第二校验，纯函数）：尾部短单元（1~8 字符）连续重复
  /// run ≥ 4 且覆盖 ≥ 12 字符 → 判复读环。启发式口径：正常一句话输出不会
  /// 以 12+ 字符的严格重复结尾；「12222」式退化（真机事故形态）必命中。
  /// 只作探针 verdict 判据，不进会话链路（会话侧复读防护归 Runner
  /// RepetitionGuard，职责分离）。
  @visibleForTesting
  static bool looksLikeRepetitionLoop(String out) {
    if (out.length < 12) return false;
    for (var unit = 1; unit <= 8; unit++) {
      if (out.length < unit * 4) continue;
      final last = out.substring(out.length - unit);
      var run = 0;
      var i = out.length;
      while (i >= unit && out.substring(i - unit, i) == last) {
        run++;
        i -= unit;
      }
      if (run >= 4 && run * unit >= 12) return true;
    }
    return false;
  }

  /// 已有有效画像 → 原样返回（跳过重探）；否则执行探针。任何探针失败都不
  /// 抛出（编排层背景任务，失败留 [DEGRADE] 并返回 null——无画像 = 未知后端，
  /// 路由交既有降级链，禁因探针故障锁死端侧）。
  ///
  /// 让位状态机（timeout-signaling W1-2）：探针占用唯一 EngineSlot（单常驻
  /// 纪律），与用户请求相撞时让位——① load 前检测到用户请求在途（引擎
  /// loading 态）即刻止步；② 探针周期内用户需求代次递增（用户 enable/生成
  /// 进入）→ 打断探针：装载失败不记坏画像（打断 ≠ 模型坏）、已载模型跳过
  /// unload 转正给前台复用、被打断的微基准结果不写画像（不可信）。探针
  /// 可重入：本轮放弃后下次导入/重探机会照常。
  Future<DispatchProfile?> probeIfNeeded(OnDeviceModelOption model) async {
    try {
      final existing = await assetManager.readDispatchProfile(model);
      if (existing != null) return existing; // 重探条件（§3）= 画像缺失/指纹漂移
      final gate = await _deviceGatePass();
      if (!gate) return null;
      if (isEngineBusy?.call() ?? false) {
        debugPrint('[on-device] admission probe skipped (user request in flight)');
        return null; // ① load 前止步：用户请求占用装载链
      }
      final first = await probe(model);
      // 第二段（AIDL backendHint #8，§4「NPU 败再探 GPU」）：首段探到 NPU
      // 判坏且 GPU 条目缺失 → 强制 GPU 档装载重探，补齐双 verdict 同体；
      // NPU 健康（无需再探）或 GPU 已有条目 → 收口。
      if (first != null) {
        final npu = first.backends['NPU'];
        if (npu != null &&
            npu.verdict != BackendVerdict.healthy &&
            first.backends['GPU'] == null) {
          debugPrint('[on-device] admission probe: NPU ${npu.verdict.name} '
              '→ probe pass 2 (forced GPU)');
          final second = await probe(model, backendHint: 'gpu');
          if (second != null) return second;
        }
      }
      return first;
    } catch (e) {
      debugPrint('[DEGRADE] admission probe orchestration: $e');
      return null;
    }
  }

  Future<bool> _deviceGatePass() async {
    try {
      final probe = await onDeviceProbe();
      if (probe == null) return true; // 未知 = 放行（DeviceTierGate 口径）
      final verdict = DeviceTierGate.check(probe);
      if (!verdict.pass) {
        debugPrint('[on-device] admission probe skipped (gate): '
            '${verdict.reason}');
      }
      return verdict.pass;
    } catch (e) {
      debugPrint('[DEGRADE] admission probe gate: $e');
      // fail-open 显性化（P0 修复）：放行决策留痕一条 fact，设备能力存疑时
      // 「端侧为何异常/变慢」的真实原因不再零感知。
      onFact?.call('端侧准入探针：设备门禁检查异常，本次按可用放行');
      return true;
    }
  }

  /// 执行探针（§4 执行协议）：load → 真生成微基准（硬超时）→ 有效性校验 →
  /// 裁决固化 → 探针后驱逐。输出非空 = HEALTHY；零产出/超时/异常 = EXCLUDED
  /// + reason（词表 = [BackendReason]）。
  ///
  /// 用户需求代次（W1-2）：进入时记 gen0，各阶段后比对——
  /// - onLoad 失败但代次已变 → 装载是被用户请求打断（引擎代次作废），非
  ///   模型坏 → 不记 EXCLUDED 直接返回 null；
  /// - 微基准后代次已变 → 会话被打断结果不可信 → 丢弃不写画像，且跳过
  ///   unload（已载模型转正给前台复用/由引擎接管清场，禁把用户正用的
  ///   模型驱逐）。
  Future<DispatchProfile?> probe(OnDeviceModelOption model,
      {String? backendHint}) async {
    final gen0 = onDeviceUserDemandGen.value;
    final observedRuntime =
        await onObservedRuntime().timeout(const Duration(seconds: 3)).catchError((_) => null);
    final key = backendKey(observedRuntime);
    final loaded = await onLoad(model, backendHint);
    if (!loaded) {
      if (onDeviceUserDemandGen.value != gen0) {
        debugPrint('[on-device] admission probe load aborted (user takeover)');
        return null; // 装载被打断 ≠ 模型坏，不记 EXCLUDED
      }
      await _record(model, key, BackendReason.opNotSupported, null);
      return null; // 装载失败归因留给 enable 链（画像只记 EXCLUDED 不误导）
    }
    BackendProfile entry;
    var userTookOver = false;
    try {
      entry = await _microBenchmark();
    } finally {
      // §4.5 探针后驱逐：COLD，用户首次真实使用重新懒加载。让位例外
      // （W1-2）：探针周期内用户请求进入 → 跳过 unload（模型转正给前台，
      // 或交引擎既有代次作废链接管清场），禁驱逐用户正用的会话。
      userTookOver = onDeviceUserDemandGen.value != gen0;
      if (!userTookOver) {
        try {
          await onUnload();
        } catch (e) {
          debugPrint('[DEGRADE] admission probe unload: $e');
        }
      } else {
        debugPrint('[on-device] admission probe yielded (user takeover, '
            'loaded model left for foreground)');
      }
    }
    if (userTookOver) return null; // 微基准被打断，结果不可信不写画像
    // 合并写入（保另一后端既有条目——双 verdict 同体契约 §1）。
    final existing = await assetManager.readDispatchProfile(model);
    final backends = <String, BackendProfile>{...?existing?.backends};
    backends[key] = entry;
    await assetManager.writeDispatchProfile(model, backends);
    final merged = await assetManager.readDispatchProfile(model);
    debugPrint('[on-device] admission probe done '
        'backend=$key verdict=${entry.verdict.name} '
        'ttftMs=${entry.ttftMs}');
    return merged;
  }

  Future<BackendProfile> _microBenchmark() async {
    final sw = Stopwatch()..start();
    var sawAny = false;
    int? ttftMs;
    final out = StringBuffer();
    try {
      await onGenerate(probePromptJson, maxTokens: probeMaxTokens)
          .timeout(hardTimeout)
          .forEach((delta) {
        if (delta.isEmpty) return;
        sawAny = true;
        ttftMs ??= sw.elapsedMilliseconds;
        out.write(delta);
      });
    } catch (e) {
      final reason = e is TimeoutException
          ? BackendReason.timeout
          : BackendReason.crash;
      debugPrint('[DEGRADE] admission probe micro-bench: $e');
      return BackendProfile(verdict: BackendVerdict.excluded, reason: reason);
    }
    // 有效性校验（§4.3）：token 必须可反解且非空——排除「成功就绪但首字 0」。
    if (!sawAny || out.isEmpty) {
      return const BackendProfile(
          verdict: BackendVerdict.excluded, reason: BackendReason.zeroOutput);
    }
    // 冒烟第二校验（§4.1）：复读环 = 配置/模板退化形态——「慢而活着」的
    // 陷阱档在 verdict 层拦截，路由查表才不放大坑。
    if (looksLikeRepetitionLoop(out.toString())) {
      debugPrint('[DEGRADE] admission probe smoke: repetition loop '
          '(${out.length} chars)');
      return const BackendProfile(
          verdict: BackendVerdict.excluded, reason: BackendReason.repetition);
    }
    return BackendProfile(
      verdict: BackendVerdict.healthy,
      ttftMs: ttftMs,
      probedAtMs: (now ?? DateTime.now)().millisecondsSinceEpoch,
    );
  }

  Future<void> _record(OnDeviceModelOption model, String key,
      BackendReason reason, int? ttftMs) async {
    final existing = await assetManager.readDispatchProfile(model);
    final backends = <String, BackendProfile>{...?existing?.backends};
    backends[key] = BackendProfile(
      verdict: BackendVerdict.excluded,
      reason: reason,
      ttftMs: ttftMs,
    );
    await assetManager.writeDispatchProfile(model, backends);
  }

  /// 观测后端 → 画像键（'NPU'/'GPU'）：票据 runtime 含 `npu` 判 NPU，
  /// 其余（litertlm-gpu / geniex GPU 兜底等）归 GPU；未知归 GPU（缺省条目
  /// 语义 = 未探，不冤枉）。
  static String backendKey(String? runtime) {
    final r = runtime?.toLowerCase() ?? '';
    return r.contains('npu') ? 'NPU' : 'GPU';
  }
}

/// 生产装配（真机链）：适配器显式装载/生成/驱逐 + 票据 runtime 观测 +
/// `ChannelLlmEngine.deviceProbe` 门禁源 + asset_manager 单例画像存储。
/// 探针独立实例（不复用混合引擎的会话态），满足 §5 与引擎生命周期解耦。
/// `byProbe: true` = 探针自驱动不 touch 用户需求代次（W1-2 让位信号只认
/// 用户路径）；`isEngineBusy` = 引擎装载链在途（用户 enable 进行中）。
final AidlOnDeviceLlmEngineAdapter _sharedProbeEngine =
    AidlOnDeviceLlmEngineAdapter(sharedOnDeviceEngine, byProbe: true);

final AdmissionProbe sharedAdmissionProbe = AdmissionProbe(
  onLoad: (m, backendHint) async =>
      await _sharedProbeEngine.enable(model: m, backendHint: backendHint) ==
      EngineStatus.ready,
  onUnload: _sharedProbeEngine.disable,
  onGenerate: (p, {required int maxTokens}) =>
      _sharedProbeEngine.generateStream(p, maxTokens: maxTokens),
  onObservedRuntime: () async {
    // 独立 binding 实例取票据（无状态通道封装，与引擎 binding 同通道同语义；
    // 引擎实例的 _binding 私有，且探针不应触碰其回调挂载面）。
    final t = await OnDeviceEngineBinding().fetchSessionTicket();
    final r = t?.runtime ?? '';
    return r.isEmpty ? null : r;
  },
  onDeviceProbe: () => ChannelLlmEngine().deviceProbe(),
  assetManager: OnDeviceAssetManager.instance,
  isEngineBusy: () =>
      sharedOnDeviceEngine.loadState.value == OnDeviceLoadState.loading,
  onFact: (m) => AppLog.instance.i(m),
);

/// 运行时坏后端记账（DispatchProfile 第二写入方，设计稿 §7）：生成链路运行时
/// 崩溃/零产出 → 当场标观测后端 EXCLUDED，下轮路由查表直跳（不让 :engine
/// 再死一次确认）。画像缺失时只记单条；已 EXCLUDED 幂等不重写。
Future<void> recordRuntimeBackendExcluded(
  OnDeviceModelOption? model,
  BackendReason reason,
) async {
  if (model == null) return;
  try {
    final t = await OnDeviceEngineBinding().fetchSessionTicket();
    final key = AdmissionProbe.backendKey(t?.runtime);
    final am = OnDeviceAssetManager.instance;
    final existing = await am.readDispatchProfile(model);
    final cur = existing?.backends[key];
    if (cur != null && cur.verdict == BackendVerdict.excluded) return;
    final backends = <String, BackendProfile>{...?existing?.backends};
    backends[key] = BackendProfile(
      verdict: BackendVerdict.excluded,
      reason: reason,
    );
    await am.writeDispatchProfile(model, backends);
    debugPrint('[DEGRADE] admission profile: runtime backend excluded '
        '($key, ${reason.name})');
  } catch (e) {
    debugPrint('[DEGRADE] admission runtime-record: $e');
  }
}

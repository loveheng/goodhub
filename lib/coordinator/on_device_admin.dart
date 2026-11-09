/// 端侧模型管理面门面（F16 依赖护栏结构修复，2026-11-03）：ui 窗口对 llm
/// 域的管理调用收敛出口（coding-standards §1.4.4 门面收敛 / §8.2 先改结构）。
/// 服务调用经 [OnDeviceAdmin] 静态转发；值类型经 `show` 导出供 UI 状态字段
/// 使用——ui 文件不再直接 import llm 域（ui→llm 白名单只减不增）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, debugPrint;
import 'package:path_provider/path_provider.dart';

import '../core/data_source.dart';
import '../llm/geniex_runtime_binding.dart'
    show GenieXRuntimeControl, GenieXStatus, LiteRtLmNpuControl,
    LiteRtLmNpuStatus;
import '../llm/on_device_admission_probe.dart' show sharedAdmissionProbe;
import '../llm/on_device_asset_manager.dart' show OnDeviceAssetManager;
import '../llm/cloud/cloud_llm.dart' show AssembledToolCall;
import '../llm/on_device_capability.dart' show AidlOnDeviceCapabilityService;
import '../llm/on_device_engine.dart'
    show OnDeviceGenPerf, OnDeviceGenPerfAware, sharedOnDeviceEngine;
import '../llm/on_device_gate_override.dart'
    show GateOverride, OnDeviceGateOverride;
import '../llm/on_device_model_catalog.dart'
    show OnDeviceModelOption, OnDeviceModelSelection;
import '../llm/on_device_session_ticket.dart' show SessionTicket;
import '../llm/on_device_residency_policy.dart'
    show OnDeviceResidencyStrategy, readNightlyBatchEnabled, readResidencyStrategy,
        setNightlyBatchEnabled;
import '../llm/on_device_residency_policy.dart' as residency_strategy
    show setResidencyStrategy;

export '../llm/on_device_residency_policy.dart'
    show readNightlyBatchEnabled, setNightlyBatchEnabled;
export '../llm/on_device_residency_policy.dart'
    show OnDeviceResidencyStrategy, residencyStrategyLabel,
        residencyStrategyDescription;
import 'host_on_device_tool.dart';
import 'supply_quota.dart';
import 'supply_task_pool.dart';

export '../llm/cloud/cloud_llm.dart'
    show AssistantMessage, CloudChatMessage, SystemMessage, UserMessage;
export '../llm/geniex_runtime_binding.dart'
    show GenieXStatus, LiteRtLmNpuStatus;
export '../llm/on_device_asset_manager.dart'
    show AssetPullProgress, OnDeviceAssetManager;
export '../llm/on_device_chat_prompt.dart' show buildOnDeviceChatPromptJsonAsync;
export '../llm/on_device_engine.dart'
    show EngineStatus, GenerationConfig, OnDeviceGenPerf,
        OnDeviceLoadState, sharedOnDeviceEngine;
export '../llm/on_device_pending_load.dart' show OnDevicePendingLoad;
export '../llm/on_device_gate_override.dart' show GateOverride;
export '../llm/on_device_history_policy.dart'
    show AnchorAndRecentHistoryPolicy, BarePromptHistoryPolicy,
    DropOldestHistoryPolicy, OnDeviceHistoryPolicy;
export '../llm/on_device_history_policy_store.dart'
    show HistoryPolicyIds, HistoryPolicySelection;
import '../llm/on_device_model_catalog.dart' show ModelRegistry;
export '../llm/on_device_model_catalog.dart'
    show ImportTarget, ModelRegistry, kOnDeviceLlamaCppEnabled,
    OnDeviceModelOption, OnDeviceModelSelection;
export '../llm/on_device_session_ticket.dart' show SessionTicket;

/// 端侧管理面服务聚合（设置段 / 导入流共用的唯一出口）。
abstract final class OnDeviceAdmin {
  // ---- 生成性能透出（S2：单例接口化后经能力接口探测取实现件专属读数）----

  static final ValueNotifier<OnDeviceGenPerf?> _noGenPerf =
      ValueNotifier<OnDeviceGenPerf?>(null);

  /// 模型资产目录只读探针（ai-capability-export 通用化轮补的取证面）：
  /// support 路径 + models/ 存在性 + 逐模型完整性对账（各文件字节 vs
  /// .asset-meta.json 的 totalBytes，口径排除 meta 自身）——scan 空时区分
  /// 「目录缺」与「条目缺/截断」。UI 层经本面取证（R1：UI 禁 dart:io）。
  static Future<Map<String, Object?>> assetProbe() async {
    final support = await getApplicationSupportDirectory();
    final modelsRoot = Directory('${support.path}/models');
    final exists = await modelsRoot.exists();
    final probe = <Map<String, Object?>>[];
    if (exists) {
      for (final d in modelsRoot.listSync()) {
        if (d is! Directory) continue;
        final name = d.path.split('/').last;
        if (name.isEmpty || name.startsWith('.')) continue;
        final files = <Map<String, Object?>>[];
        var actualBytes = 0;
        for (final f in d.listSync()) {
          if (f is! File) continue;
          final sz = f.lengthSync();
          // meta 期望值只计资产文件、不含 .asset-meta.json 自身——对账口径
          // 排除 meta（差值 = meta 大小属正常形态）。
          final isMeta = f.path.endsWith('/${ModelRegistry.metaFileName}');
          if (!isMeta) actualBytes += sz;
          files.add({'name': f.path.split('/').last, 'bytes': sz});
        }
        var metaBytes = 0;
        String metaRaw = '';
        final metaFile = File('${d.path}/${ModelRegistry.metaFileName}');
        if (metaFile.existsSync()) {
          metaRaw = metaFile.readAsStringSync();
          try {
            final meta =
                jsonDecode(metaRaw) as Map<String, dynamic>;
            metaBytes = (meta['totalBytes'] as num?)?.toInt() ?? 0;
          } on Object {
            // meta 解析失败 = 期望大小按 0（对账跳过，探针只读不阻断）
          }
        }
        probe.add({
          'dirName': name,
          'files': files,
          'actualBytes': actualBytes,
          'metaTotalBytes': metaBytes,
          'complete': metaBytes == 0 || actualBytes == metaBytes,
          if (metaRaw.isNotEmpty)
            'metaJson': metaRaw.length > 800
                ? '${metaRaw.substring(0, 800)}…'
                : metaRaw,
        });
      }
    }
    return {
      'supportPath': support.path,
      'modelsDirExists': exists,
      'models': probe,
    };
  }

  /// §6.3 后台排空预算（ai-capability-export）：单轮连续耗时上限（真机调优
  /// 起步值 30s，非拍板常量）。
  static const Duration kDrainBatchBudget = Duration(seconds: 30);

  /// §6.3 批间强制冷却（防 allow_deferred 批任务长占单槽触发极端温控）。
  static const Duration kDrainBatchCooldown = Duration(seconds: 3);

  /// W6-b 顺风车排空（on-device-residency 第七节）：WARM 窗口内排空异步
  /// 任务池（≤[maxTasks] 条，K11 抢占回池语义由 requeue 承载）。Run 收口后
  /// 由页面调用（用户阅读空闲期）；失败逐条留痕不反噬主路径。
  ///
  /// ai-capability-export §6.3 系统级护栏「后台排空预算」：单轮连续耗时上限
  /// [kDrainBatchBudget] + 批间冷却 [kDrainBatchCooldown]——防 allow_deferred
  /// 批任务长占单槽触发极端温控（真机调优起步值，非拍板常量）。
  static Future<void> drainSupplyPool({int maxTasks = 3}) async {
    final pool = SupplyTaskPool.instance;
    pool.debugDump('drain-entry');
    final executor = HostOnDeviceToolExecutor(
      AidlOnDeviceCapabilityService(sharedOnDeviceEngine),
      quota: SupplyQuota(),
      taskPool: pool,
    );
    final sw = Stopwatch()..start();
    for (var i = 0; i < maxTasks; i++) {
      if (sw.elapsed > kDrainBatchBudget) {
        debugPrint('[RESIDENCY] drain budget hit '
            '(${sw.elapsedMilliseconds}ms > ${kDrainBatchBudget.inMilliseconds}ms)，'
            '余量任务留待下轮');
        return;
      }
      final entry = await pool.claimNext();
      debugPrint('[RESIDENCY] drain claimNext[$i]: ${entry?.taskId ?? "null"} status=${entry?.status.name ?? "-"}');
      if (entry == null) return;
      try {
        final r = await executor.execute(AssembledToolCall(
          id: 'drain-${entry.taskId}',
          name: HostOnDeviceToolExecutor.toolName,
          argumentsJson: jsonEncode({
            'instruction': entry.instruction,
            'input': entry.input,
          }),
        ), callerKeyOverride: entry.callerKey);
        if (r.isError) {
          // 引擎忙/死亡：回池（毒丸计数累计，超限死信），停止本轮排空。
          await pool.requeue(entry.taskId);
          debugPrint('[DEGRADE] supply-drain: ${r.content}');
          return;
        }
        await pool.completeTask(entry.taskId, r.content);
      } on Object catch (e) {
        await pool.requeue(entry.taskId);
        debugPrint('[DEGRADE] supply-drain: $e');
        return;
      }
      // 批间强制冷却（§6.3：防长占单槽触发极端温控；末条后多等一次无害）。
      await Future<void>.delayed(kDrainBatchCooldown);
    }
  }

  /// W6-c 夜间批处理（on-device-residency 第七节契机 B）：充电 + 后台 +
  /// 开关开启时批量排空任务池（ADR 已立 2026-11-07）。调用方 = main.dart
  /// 生命周期沿（paused/hidden + 充电检测）。分块语义由 [maxTasks] 上限 +
  /// 逐任务 WAL 提交承载；拔线中断由调用方（main.dart Timer cancel）兜底。
  static Future<void> runNightlyBatch({int maxTasks = 20}) async {
    final enabled = await readNightlyBatchEnabled();
    if (!enabled) return;
    final pool = SupplyTaskPool.instance;
    final executor = HostOnDeviceToolExecutor(
      AidlOnDeviceCapabilityService(sharedOnDeviceEngine),
      quota: SupplyQuota(),
      taskPool: pool,
    );
    var done = 0;
    for (var i = 0; i < maxTasks; i++) {
      final entry = await pool.claimNext();
      if (entry == null) break;
      try {
        final r = await executor.execute(AssembledToolCall(
          id: 'nightly-${entry.taskId}',
          name: HostOnDeviceToolExecutor.toolName,
          argumentsJson: jsonEncode({
            'instruction': entry.instruction,
            'input': entry.input,
          }),
        ), callerKeyOverride: entry.callerKey);
        if (r.isError) {
          await pool.requeue(entry.taskId);
          debugPrint('[DEGRADE] nightly-batch: ${r.content}');
          continue;
        }
        await pool.completeTask(entry.taskId, r.content);
        done++;
      } on Object catch (e) {
        await pool.requeue(entry.taskId);
        debugPrint('[DEGRADE] nightly-batch: $e');
      }
    }
    debugPrint('[RESIDENCY] nightly-batch done=$done');
  }

  // ---- W6-c 夜间批处理开关（on-device-residency 第七节契机 B）----

  static Future<bool> nightlyBatchEnabled() => readNightlyBatchEnabled();
  static Future<void> setNightlyBatch(bool v) => setNightlyBatchEnabled(v);

  // ---- P1 用户面驻留策略档位（on-device-residency 策略单源，residency-strategy-ui）----

  static Future<OnDeviceResidencyStrategy> residencyStrategy() =>
      readResidencyStrategy();

  /// 写档位并 best-effort 重放 bind 配置：warmup()（bind+waitReady，不触权重
  /// 装载——懒加载立法不受影响）触发原生 bind 处理器刷新档位字段，已连接时
  /// 就地重跑 initEngine 即席生效；未连接随下次握手生效。
  ///
  /// 重放**不 await**（unawaited 后件）：设置面反馈只等偏好落盘，bind 通道
  /// 挂起/失败不拖 UI——重放自身 DEGRADE 留痕，首次请求自有 bind 兜底。
  static Future<void> setResidencyStrategy(OnDeviceResidencyStrategy v) async {
    await residency_strategy.setResidencyStrategy(v);
    unawaited(_replayResidencyBind());
  }

  static Future<void> _replayResidencyBind() async {
    try {
      await sharedOnDeviceEngine.warmup();
    } on Object catch (e) {
      debugPrint('[DEGRADE] residency-strategy replay: $e');
    }
  }

  /// W6 联调入口（on-device-residency 第七节）：模拟外部调用方以
  /// allow_deferred=true 调用 on_device_complete——冷态时入池回执，
  /// WARM 时同步直出。返回联合态 JSON（与导出面 content 同形）。
  static Future<String> simulateDeferredCall(
      {required String instruction, required String input}) async {
    final executor = HostOnDeviceToolExecutor(
      AidlOnDeviceCapabilityService(sharedOnDeviceEngine),
      quota: SupplyQuota(),
      taskPool: SupplyTaskPool.instance,
    );
    final r = await executor.execute(AssembledToolCall(
      id: 'sim-deferred-${DateTime.now().millisecondsSinceEpoch}',
      name: HostOnDeviceToolExecutor.toolName,
      argumentsJson: jsonEncode({
        'instruction': instruction,
        'input': input,
        'allow_deferred': true,
      }),
    ), callerKeyOverride: kPrimaryDataSourcePackage);
    return r.content;
  }

  /// 聚焦 bind 预热（P1-d，on-device-residency）：输入框首聚焦触发
  /// bind+waitReady（**不触权重装载**——懒加载立法不受影响）；预热失败静默
  /// （首次请求自有快速暖机兜底）。
  static Future<void> warmupTouch() async {
    try {
      await sharedOnDeviceEngine.warmup();
    } on Object catch (e) {
      debugPrint('[DEGRADE] warmup-touch: $e');
    }
  }

  /// 最近一次端侧生成性能透出（实现方未实现能力接口 = 恒 null 通知器）。
  static ValueListenable<OnDeviceGenPerf?> onDeviceLastGenPerf() {
    final engine = sharedOnDeviceEngine;
    if (engine is OnDeviceGenPerfAware) {
      return engine.lastGenPerf;
    }
    return _noGenPerf;
  }

  // ---- 增配运行库（geniex_runtime_binding）----

  /// 增配镜像列表读取（GenieX/LiteRT-LM 双族共用一套持久化）。
  static Future<List<String>> loadMirrors() => GenieXRuntimeControl.loadMirrors();

  static Future<void> saveMirrors(List<String> mirrors) =>
      GenieXRuntimeControl.saveMirrors(mirrors);

  /// GenieX 主通路增配状态。
  static Future<GenieXStatus> geniexStatus() => GenieXRuntimeControl.status();

  /// 受理 GenieX 增配安装（true = 已受理；进度/完成经 [npuListen] 反投）。
  static Future<bool> geniexInstall(List<String> mirrors) =>
      GenieXRuntimeControl.install(mirrors);

  /// 卸载 GenieX 增配运行库（端侧 LLM 收口云端，可随时重装）。
  static Future<bool> geniexUninstall({bool deleteCache = false}) =>
      GenieXRuntimeControl.uninstall(deleteCache: deleteCache);

  /// 增配运行库状态（通道不可用 = 不支持快照，UI 隐藏入口）。
  static Future<LiteRtLmNpuStatus> npuStatus() => LiteRtLmNpuControl.status();

  /// 受理增配安装（true = 已受理；进度/完成经 [npuListen] 反投）。
  static Future<bool> npuInstall(List<String> mirrors) =>
      LiteRtLmNpuControl.install(mirrors);

  /// 增配通道事件订阅（litertlm + geniex 合并分发，禁各自独立订阅），
  /// 返回取消订阅闭包。
  static void Function() npuListen({
    void Function(int pct)? onGeniexProgress,
    void Function(bool ok)? onGeniexDone,
    required void Function(int pct) onProgress,
    required void Function(bool ok) onDone,
  }) =>
      LiteRtLmNpuControl.listen(
        onGeniexProgress: onGeniexProgress,
        onGeniexDone: onGeniexDone,
        onProgress: onProgress,
        onDone: onDone,
      );

  // ---- 路由覆盖偏好（on_device_gate_override）----

  static Future<GateOverride> readGateOverride() => OnDeviceGateOverride.read();

  static Future<void> writePreferOnDevice(bool v) =>
      OnDeviceGateOverride.writePreferOnDevice(v);

  // ---- 资产与准入（asset_manager / admission_probe）----

  /// 资产管理面单例（列表/导入/删除经此）。
  static OnDeviceAssetManager get assets => OnDeviceAssetManager.instance;

  /// 导入完成后准入探针（DispatchProfile §3）：后台编排不挡 UI。
  static void probeAdmission(String dirName) => unawaited(
      sharedAdmissionProbe.probeIfNeeded(OnDeviceModelOption.fromInstalled(dirName)));

  // ---- 模型选择（on_device_model_catalog）----

  static Future<void> selectModel(String dirName) =>
      OnDeviceModelSelection.write(dirName);

  static Future<OnDeviceModelOption?> readSelectedModel() =>
      OnDeviceModelSelection.read();

  // ---- 运行环境实况（on_device_engine_aidl 票据面，2026-11-05）----

  /// 实况票据（runtime + runtimeDetail = 计算单元/unfit 原因/sdk 版本）——
  /// 资源中心端侧模型 Tab 的误判发现面。null = :engine 不可达/未知态。
  static Future<SessionTicket?> sessionTicket() =>
      sharedOnDeviceEngine.sessionTicket();
}

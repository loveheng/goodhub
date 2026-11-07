/// 混合引擎路由探针采集（extensibility-hardening S3 自 hybrid_cloud_engine 拆出）：
/// 判定链消费的全部现场取证，单点采集、禁二次读取（窗口值源 S14c 单次读取纪律）。
///
/// 纯采集零路由决策——判定 = `evaluateDeviceRoute`（capability_router 纯函数）、
/// 消费 = HybridCloudEngine.send 编排；本件只回答「现场是什么」。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/capability_requirement.dart';
import '../core/tokens.dart' show estimateTokens;
import '../llm/cloud/cloud_llm.dart';
import '../llm/llm.dart';
import '../llm/on_device_chat_prompt.dart';
import '../llm/on_device_engine.dart';
import '../llm/on_device_engine_binding.dart';
import '../llm/on_device_history_policy_store.dart';
import '../llm/on_device_model_catalog.dart';
import 'capability_router.dart';
import 'degradation_controller.dart';

/// 端侧 prompt 构造结果：实际送达 :engine 的载荷 + 裁剪后内容字符数 +
/// 选中模型（窗口值/采样参数同源），供窗口准入与超窗预检共用。
typedef HybridDevicePrompt = ({
  String promptJson,
  int contentChars,
  OnDeviceModelOption? selected,
});

/// 路由判定链消费的现场取证集（send 一次采集，全段复用）。
class HybridRouteProbes {
  const HybridRouteProbes({
    required this.offline,
    required this.gate,
    required this.requirement,
    required this.deviceCold,
    required this.wantDevice,
    required this.foreground,
    required this.subject,
    required this.selectedModel,
    required this.preparedPrompt,
    required this.residentMatched,
    required this.availMemBytes,
    required this.quotaExceeded,
  });

  final bool offline;
  final ({bool pass, String reason, bool unknown}) gate;
  final CapabilityRequirement requirement;
  final bool deviceCold;
  final bool wantDevice;
  final bool foreground;
  final CallerSubject subject;
  final OnDeviceModelOption? selectedModel;

  /// 裁剪后实际载荷（S14c：估算与超窗预检禁二次构造）；wantDevice=false 时 null。
  final HybridDevicePrompt? preparedPrompt;
  final bool? residentMatched;
  final int? availMemBytes;
  final bool quotaExceeded;

  /// 输入估算（窗口段消费；preparedPrompt 为 null 时 null = 双未知不拦口径）。
  int? get inputEstimateTokens => preparedPrompt?.contentChars;
}

/// 采集判定链现场（S3 自 send 编排段拆出：探针采集独立件，纯读取零决策）。
Future<HybridRouteProbes> collectHybridRouteProbes({
  required CloudChatRequest request,
  required DegradationController controller,
  required OnDeviceLlmEngine? onDevice,
  required OnDeviceEnableCapable? enableCapable,
  required bool preferOnDevice,
  required Future<bool> Function()? isOfflineProbe,
  required Future<bool> Function()? isForegroundProbe,
  required Future<({bool pass, String reason})> Function()? deviceTierGate,
  required bool Function(List<CloudToolSchema> tools)? deviceToolPolicy,
  required Future<OnDeviceModelOption?> Function()? onDeviceModelResolver,
  required Future<int?> Function()? availMemProbe,
  required bool Function()? quotaChecker,
}) async {
  // —— 物理断网探测（探测异常视作在线：方向=朝向更丰富路径，P2-1 口径）——
  var offline = false;
  final offlineProbe = isOfflineProbe;
  if (offlineProbe != null) {
    try {
      offline = await offlineProbe();
    } catch (e) {
      // DEGRADE: 探测失败视作在线——反向会让用户在云端可用时静默失去云端能力。
      debugPrint('[DEGRADE] hybrid-offline-probe: $e');
    }
  }
  // —— 设备门禁（advisory；2026-10-31 用户裁决：只留痕不拦截，重探一次仍
  // 失败按 unknown 如实留痕）——
  var gate = (pass: true, reason: '无门禁位', unknown: false);
  final gateProbe = deviceTierGate;
  if (gateProbe != null) {
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final r = await gateProbe();
        gate = (pass: r.pass, reason: r.reason, unknown: false);
        break;
      } catch (e) {
        lastError = e;
        debugPrint('[DEGRADE] hybrid-device-gate (attempt $attempt): $e');
      }
    }
    if (gate.unknown) {
      gate = (
        pass: false,
        reason: '门禁探测异常（重试后仍失败：$lastError），端侧状态未知',
        unknown: true,
      );
    }
  }
  // —— 判据声明（S14：显式 requirement 优先，缺省按请求形状推导——等价旧
  // toolFaceOk 判据，零行为变化）——
  final requirement = request.requirement ??
      deriveChatRequirement(request.tools, deviceToolPolicy);
  final deviceCold = enableCapable?.loadState.value != OnDeviceLoadState.ready;
  final wantDevice = offline || !controller.shouldUseCloud || preferOnDevice;
  final canDeviceCandidate = onDevice != null;
  // 前台态判定（场景 A/B/C 用）：探针缺省或异常 → 视为后台（保守：宁暂存等
  // 前台，不误切云外发数据）。
  var foreground = false;
  if (canDeviceCandidate && wantDevice) {
    final fgProbe = isForegroundProbe;
    if (fgProbe != null) {
      try {
        foreground = await fgProbe();
      } catch (e) {
        debugPrint('[DEGRADE] hybrid-foreground-probe: $e');
      }
    }
  }
  final subject =
      foreground ? CallerSubject.hostForeground : CallerSubject.hostBackground;
  // —— 窗口值源单次读取（S14c：窗口段/画像段/驻留取证三处复用）——
  final selectedModel = canDeviceCandidate && wantDevice
      ? await _readSelectedModel(onDeviceModelResolver)
      : null;
  HybridDevicePrompt? preparedPrompt;
  if (selectedModel != null) {
    preparedPrompt = await buildDevicePrompt(request,
        selected: selectedModel, onDeviceModelResolver: onDeviceModelResolver);
  }
  // —— 驻留资产匹配度取证（K19）：仅端侧已就绪时查票据——冷态下无驻留
  // 可言，换驻留禁令不适用。票据 modelId 与装载入参同源（modelIdOf =
  // dirName@digest），前缀比对目标 dirName；票据不可达（3s 超时）= 未知不判，
  // 交装载链路对账。
  bool? residentMatched;
  if (onDevice != null && !deviceCold && selectedModel != null) {
    try {
      final ticket = await OnDeviceEngineBinding().fetchSessionTicket();
      final resident = ticket?.modelId ?? '';
      if (resident.isNotEmpty) {
        final dir = selectedModel.dirName;
        residentMatched = resident == dir || resident.startsWith('$dir@');
      }
    } catch (e) {
      debugPrint('[DEGRADE] hybrid resident-match probe: $e');
    }
  }
  // —— 动态准入取证（S14d）：探针异常 = null 不判，禁把探针故障读成内存紧张。
  int? availMemBytes;
  if (onDevice != null && availMemProbe != null) {
    try {
      availMemBytes = await availMemProbe();
    } catch (e) {
      debugPrint('[DEGRADE] hybrid availMem probe: $e');
    }
  }
  final quotaExceeded = onDevice != null && (quotaChecker?.call() ?? false);
  return HybridRouteProbes(
    offline: offline,
    gate: gate,
    requirement: requirement,
    deviceCold: deviceCold,
    wantDevice: wantDevice,
    foreground: foreground,
    subject: subject,
    selectedModel: selectedModel,
    preparedPrompt: preparedPrompt,
    residentMatched: residentMatched,
    availMemBytes: availMemBytes,
    quotaExceeded: quotaExceeded,
  );
}

/// 选中模型单一读取口（注入优先，缺省落盘选择）。
Future<OnDeviceModelOption?> _readSelectedModel(
  Future<OnDeviceModelOption?> Function()? resolver,
) =>
    resolver?.call() ?? OnDeviceModelSelection.read();

/// 构造端侧实际载荷并给出裁剪后内容字符数（send 主路径与旁路兜底共用单源，
/// 禁二次构造 / 禁两套估法）。
///
/// 窗口准入（S14c `inputEstimateTokens`）与 P1-5 超窗预检**必须复用本结果**：
/// 宿主聊天的 system 指令 + 工具面 + 历史动辄数千字符，而端侧默认策略
/// ⓪ 真裸只把最新 user 轮送进 :engine。按裁剪前的原始消息全量估算，
/// 1280 窗口的 1B bundle 每轮都会算出 >704 字符而误判超窗（真机：选中
/// 1B 即报「输入超出端侧模型上下文窗口且未配置云端兜底」）。
///
/// `contentChars` = JSON 解码后各 content 长度之和（[estimateTokens] 字符级
/// 上界口径），不含 +64 脚手架开销——判据侧由 `onDeviceInputOverflows`
/// 统一补齐，禁在此重复计入。
Future<HybridDevicePrompt> buildDevicePrompt(
  CloudChatRequest request, {
  OnDeviceModelOption? selected,
  Future<OnDeviceModelOption?> Function()? onDeviceModelResolver,
}) async {
  final model = selected ?? await _readSelectedModel(onDeviceModelResolver);
  final deviceKey = model?.dirName ?? 'device-default';
  final devicePolicyId =
      await HistoryPolicySelection.readForModel(deviceKey, device: true);
  final promptJson = await buildOnDeviceChatPromptJsonAsync(
    request.messages,
    contextTokens: model?.contextTokens,
    historyPolicy: HistoryPolicySelection.resolve(devicePolicyId),
  );
  var contentChars = 0;
  for (final m
      in (jsonDecode(promptJson) as List).cast<Map<String, dynamic>>()) {
    contentChars += estimateTokens(m['content'] as String? ?? '');
  }
  return (
    promptJson: promptJson,
    contentChars: contentChars,
    selected: model,
  );
}

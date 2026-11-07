/// 混合引擎云腿（extensibility-hardening S3 自 hybrid_cloud_engine 拆出）：
/// 云端发送 + 自适应看门狗 + 恢复切端兜底——**恢复逻辑随腿走**（云失败 → 切端
/// 是本腿职责；跨腿的「端失败 → 切云」在 DeviceLeg，两者不做装饰器互包）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/errors/cloud_llm_error.dart';
import '../core/errors/inference_error.dart';
import '../llm/cloud/byok_store.dart';
import '../llm/on_device_residency_metrics.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/on_device_history_policy_store.dart';
import '../llm/on_device_model_catalog.dart';
import 'degradation_controller.dart';
import 'hybrid_device_leg.dart';
import 'hybrid_route_probes.dart';

class HybridCloudLeg {
  HybridCloudLeg({
    required this.controller,
    required this.deviceLegOf,
    required this.devicePromptOf,
    required this.cloudForbidden,
  });

  final DegradationController controller;

  /// 端侧腿 thunk（云端恢复类兜底切端复用；thunk 断装配互引环——云腿恢复
  /// 切端 ↔ 端腿失败切云，且端腿仅在端侧可用时惰性构造）。禁止裸流直连
  /// 端侧引擎。
  HybridDeviceLeg get deviceLeg => deviceLegOf();
  final HybridDeviceLeg Function() deviceLegOf;

  /// 端侧载荷构造单源（buildDevicePrompt，禁二次估法）。
  final Future<HybridDevicePrompt> Function(
    CloudChatRequest request, {
    OnDeviceModelOption? selected,
  }) devicePromptOf;

  /// 排除位守卫单点（S14e K10：判定单一入口，禁各处散判 localOnly）。
  final bool Function(CloudChatRequest request) cloudForbidden;

  /// 当前生效云端模型的策略偏好 id：生效 profile（用户显式选择）> 列表首位；
  /// 无任何 profile 返 null（云端无模型 → 无策略面）。读取失败按 null 收口
  /// （DEGRADE 留痕，不阻断云发送）。
  Future<String?> _cloudModelPolicyId() async {
    try {
      final store = ByokStore();
      final preferred = await store.preferredProfileId();
      if (preferred != null) {
        return await HistoryPolicySelection.readForModel(preferred);
      }
      final profiles = await store.load();
      if (profiles.isEmpty) return null;
      return await HistoryPolicySelection.readForModel(profiles.first.id);
    } on Object catch (e) {
      debugPrint('[DEGRADE] hybrid: 云端历史策略偏好读取失败: $e');
      return null;
    }
  }

  /// 云腿发送：历史策略裁剪 → 自适应看门狗承载 → 恢复类异常按类切端。
  ///
  /// [allowDeviceFallback] = 当次请求允许端侧兜底（带工具请求 false——端侧
  /// 单发不产工具调用，兜底必失败）；画像双坏调用方显式传 false（查表即决策，
  /// 禁降级链再撞坏后端）。
  Stream<CloudStreamEvent> send(
    CloudLlmEngine cloud,
    CloudChatRequest request, {
    required bool allowDeviceFallback,
    void Function()? onActivity,
  }) async* {
    // 历史策略接线（2026-11-02）：策略挂模型本身（用户拍板）——按生效
    // BYOK profile id 取偏好，非默认 ① 时裁剪消息后再发（默认档整体跳过 =
    // 存量零变化；工具链路内部豁免不裁剪）。
    // R-P0 驻留观测面（S-R0-b）：云腿入口 Piggyback（命中率分母）。
    onDeviceResidencyMetrics
        .eventSync('send', {'mode': 'cloud', 'fallbackAllowed': allowDeviceFallback});
    final cloudPolicyId = await _cloudModelPolicyId();
    var effective = request;
    if (cloudPolicyId != null &&
        cloudPolicyId != HistoryPolicyIds.dropOldest) {
      final trimmed = await applyHistoryPolicyToCloudMessages(
        request.messages,
        HistoryPolicySelection.resolve(cloudPolicyId),
        HistoryPolicySelection.kCloudHistoryCharBudget,
      );
      if (!identical(trimmed, request.messages)) {
        effective = CloudChatRequest(
          messages: trimmed,
          tools: request.tools,
          temperature: request.temperature,
          maxTokens: request.maxTokens,
          requirement: request.requirement,
        );
      }
    }
    try {
      // 流内间隙判定改造（「用其他方式判断」而非固定 30s 死计时）：
      // 旧逻辑以「两事件间静默 > interEventGapTimeout(30s)」判卡流——思考期
      // 模型不产 token 即被误杀（带工具请求无端侧兜底 → 直接 rethrow 中断任务）。
      // 新逻辑改为「传输层字节活体 + 自适应预算（无上限）」：
      //  - onActivity：底层每收到一帧字节（含 SSE 心跳注释帧）即证明连接活着，
      //    重置看门狗；心跳帧只作存活证据、不作工作推进（D2 正交语义不变）。
      //  - 预算自适应：首字节前用 firstTokenTimeout 快速判死连接；已有产出后随
      //    请求已耗时放宽（interEventGapTimeout 为下限、**无上限**，[maxThinkingGap]
      //    已移除），长思考不再被固定 30s 掐断；活体连接永不误杀，仅真死连接（持续
      //    无字节）被兜底下限捕获，其余交给人工「中止」（状态带显示已耗时）。
      final sw = Stopwatch()..start();
      var sawActivity = false;
      var sawOutput = false;
      final ctrl = StreamController<CloudStreamEvent>();
      Timer? watchdog;
      late final StreamSubscription<CloudStreamEvent> srcSub;
      Duration computeBudget() {
        if (!sawActivity) return controller.firstTokenTimeout;
        // 已有活体信号：预算随请求已耗时放宽（0.5×），下限 interEventGapTimeout、
        // **无上限**——活体连接（含 SSE 心跳）永不掐断，长思考不误杀；仅真死连接
        // （持续无字节）被兜底下限捕获，其余交给人工「中止」（状态带显示已耗时）。
        final grown = Duration(
          milliseconds: (sw.elapsed.inMilliseconds * 0.5).round(),
        );
        final floor = controller.interEventGapTimeout;
        return grown <= floor ? floor : grown;
      }

      void fireTimeout() {
        if (ctrl.isClosed) return;
        ctrl.addError(TimeoutException(
          '云端流内间隙超时（首 token ${controller.firstTokenTimeout.inSeconds}s / '
          '自适应下限 ${controller.interEventGapTimeout.inSeconds}s，随请求已耗时放宽、'
          '无上限；心跳帧存活即不触发，仅真死连接触发）',
        ));
        ctrl.close();
        srcSub.cancel();
      }

      void armWatchdog() {
        watchdog?.cancel();
        watchdog = Timer(computeBudget(), fireTimeout);
      }

      void noteActivity() {
        sawActivity = true;
        if (!ctrl.isClosed) armWatchdog();
      }

      srcSub = cloud.send(effective, onActivity: noteActivity).listen(
        (e) {
          noteActivity();
          if (e is CloudTextDelta || e is CloudToolCallDelta) sawOutput = true;
          if (!ctrl.isClosed) ctrl.add(e);
        },
        onError: (Object err, StackTrace st) {
          watchdog?.cancel();
          if (!ctrl.isClosed) {
            ctrl.addError(err, st);
            ctrl.close();
          }
        },
        onDone: () {
          watchdog?.cancel();
          if (!ctrl.isClosed) ctrl.close();
        },
        cancelOnError: false,
      );
      // 首字节前的死连接快速判据（firstTokenTimeout）。
      armWatchdog();
      try {
        await for (final e in ctrl.stream) {
          yield e;
        }
        controller.reportSuccess();
        // T7 实测新增：流式契约干净完成但零可见产出——推理型模型把 max_tokens
        // 烧在思维链（reasoning_content 不产可见 delta）时出现。产出优先语义下
        // 走端侧兜底；无兜底（带工具）显式暴露，禁静默空产出。
        if (!sawOutput) {
          if (allowDeviceFallback) {
            yield* deviceLeg.send(request,
                reason: '云端空产出（流完成但零可见内容）');
          } else {
            throw const InferenceException('云端空产出（流完成但零可见内容/工具调用）');
          }
        }
      } finally {
        watchdog?.cancel();
        await srcSub.cancel();
      }
    } on TimeoutException {
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* deviceLeg.send(request, reason: '云端首 Token 超时');
      } else {
        rethrow;
      }
    } on CloudHttpException catch (e) {
      // 仅 5xx/429 计入降级判据；401/403 等客户端侧错误不降级（换端侧也治不了坏 Key），
      // 但当次请求仍端侧兜底（产出优先）
      controller.reportServerError(e.statusCode ?? 0);
      if (allowDeviceFallback) {
        yield* deviceLeg.send(request,
            reason: '云端 HTTP ${e.statusCode ?? '流内错误'}');
      } else {
        rethrow;
      }
    } on CloudNetworkException {
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* deviceLeg.send(request, reason: '云端连接失败/超时');
      } else {
        rethrow;
      }
    } on Exception catch (e) {
      // 语义排除：空产出（流干净完成但零可见内容）与协议违规是**设计上直露**
      // 的结论性失败（UI 各有白话文案），不是传输中断——原样上抛，不进兜底。
      if (e is InferenceException || e is CloudProtocolException) rethrow;
      // 兜底（2026-10-21 真机实测教训，SiliconFlow「Connection closed while
      // receiving data」）：流内异常若不在上述三类之列（传输层未映射的裸
      // ClientException / FormatException / 其他 Exception），旧行为直接穿透
      // 到 UI 错误卡炸整轮会话。按传输中断语义收口：计入降级判据 + 当次
      // 端侧兜底（产出优先）；无兜底（带工具请求）包装为 CloudNetworkException
      // 上抛——UI 白话卡据此给「连不上推理服务」而非裸异常文案，原始异常
      // 信息内嵌保留（错误卡 detail 可复制）。禁静默吞：失败对调用方可见。
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* deviceLeg.send(request, reason: '云端流异常中断: $e');
      } else {
        throw CloudNetworkException('云端流异常中断: $e');
      }
    }
  }
}

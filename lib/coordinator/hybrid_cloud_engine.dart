/// 混合引擎：按降级控制器在云端流式与端侧单发之间路由（M2-T2，architecture §2）。
///
/// - **端侧职责硬约束（§2）**：端侧不承担通用调度——仅当请求**无工具**（任务 note
///   类单发提取）时才可走端侧；带工具请求永远走云端；
/// - **判据触发**：云端失败/超时，当次请求立即端侧兜底（产出优先），并计入
///   控制器供后续请求路由；端侧也不可用时原样上抛（禁静默吞——调用方产出可观测 note）；
/// - **抢占语义（§2）**：云端恢复不抢占进行中推理——路由只发生在请求起点，天然满足；
/// - **取消**：cancel 订阅即级联取消（§10 Abort 级联①步）——云端断流取消底层请求，
///   端侧经 StreamController onCancel 立即调 cancelActive 终止原生生成。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/errors/cloud_llm_error.dart';
import '../core/errors/inference_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/llm.dart';
import 'degradation_controller.dart';

class HybridCloudEngine implements CloudLlmEngine {
  HybridCloudEngine({
    required this.controller,
    this.cloud,
    this.onDevice,
    this.isOfflineProbe,
    this.deviceTierGate,
  });

  final DegradationController controller;

  /// 云端引擎（null = 未配置 BYOK，仅端侧路径）。
  final CloudLlmEngine? cloud;

  /// 端侧引擎（null = 引擎未挂载/平台不支持）。
  final OnDeviceLlmEngine? onDevice;

  /// 物理断网探测（注入；null = 不探测视作在线）。判据「断网即切」的探测位，
  /// T3 接 Connectivity 实测。
  final Future<bool> Function()? isOfflineProbe;

  /// 设备分级门禁（§16，注入；null = 不门禁）。裁决 (pass, reason)；
  /// 关闸 ≡ 端侧不可用（路由语义与 onDevice=null 一致），reason 留痕可观测。
  final Future<({bool pass, String reason})> Function()? deviceTierGate;

  /// 断网探测（无探测位 = 视作在线）。
  Future<bool> _isOffline() async {
    final probe = isOfflineProbe;
    if (probe == null) return false;
    try {
      return await probe();
    } catch (e) {
      // DEGRADE: 探测失败视作在线——云端路径自有判据兜底，留痕可观测。
      debugPrint('[DEGRADE] hybrid-offline-probe: $e');
      return false;
    }
  }

  /// 设备门禁查询（无门禁位 = 放行）。
  Future<({bool pass, String reason})> _deviceGate() async {
    final gate = deviceTierGate;
    if (gate == null) return (pass: true, reason: '无门禁位');
    try {
      return await gate();
    } catch (e) {
      // DEGRADE: 门禁探测失败放行——探针异常不应拖垮兜底路径，留痕可观测。
      debugPrint('[DEGRADE] hybrid-device-gate: $e');
      return (pass: true, reason: '门禁探测异常放行');
    }
  }

  @override
  String get name => cloud == null
      ? '混合引擎（仅端侧）· ${onDevice?.name ?? '无'}'
      : '混合引擎 · ${cloud!.name}';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request) async* {
    final offline = await _isOffline();
    final gate = await _deviceGate();
    if (!gate.pass) {
      // 门禁关闸留痕（§16）：关闸 ≡ 端侧不可用，路由语义与 onDevice=null 一致
      debugPrint('[HybridEngine] 端侧门禁未过（${gate.reason}）');
    }
    final canDevice = request.tools.isEmpty && onDevice != null && gate.pass;
    if (canDevice && (offline || !controller.shouldUseCloud)) {
      yield* _deviceSend(request, reason: offline ? '物理断网' : '云端降级冷却期');
      return;
    }
    final c = cloud;
    if (c == null) {
      if (canDevice) {
        yield* _deviceSend(request, reason: '云端未配置');
        return;
      }
      throw const InferenceException('无可用推理引擎：云端未配置且端侧不可用');
    }
    yield* _cloudSend(c, request, allowDeviceFallback: canDevice);
  }

  Stream<CloudStreamEvent> _cloudSend(
    CloudLlmEngine c,
    CloudChatRequest request, {
    required bool allowDeviceFallback,
  }) async* {
    try {
      // Stream.timeout 逐事件计隙：首事件迟到（首 Token 判据）与流中卡顿共用同一阈值，
      // 超时注入错误并取消底层订阅（级联断开云端连接）。
      // 注意：async* 里 try 包 yield* 接不住子流错误（sdk#30552），必须 await for + yield
      await for (final e in c.send(request).timeout(
        controller.firstTokenTimeout,
        onTimeout: (sink) => sink.addError(TimeoutException(
            '云端首 Token/事件间隙超时（判据 ${controller.firstTokenTimeout.inSeconds}s）')),
      )) {
        yield e;
      }
      controller.reportSuccess();
    } on TimeoutException {
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* _deviceSend(request, reason: '云端首 Token 超时');
      } else {
        rethrow;
      }
    } on CloudHttpException catch (e) {
      // 仅 5xx/429 计入降级判据；401/403 等客户端侧错误不降级（换端侧也治不了坏 Key），
      // 但当次请求仍端侧兜底（产出优先）
      controller.reportServerError(e.statusCode ?? 0);
      if (allowDeviceFallback) {
        yield* _deviceSend(request, reason: '云端 HTTP ${e.statusCode ?? '流内错误'}');
      } else {
        rethrow;
      }
    } on CloudNetworkException {
      controller.reportTransportTimeout();
      if (allowDeviceFallback) {
        yield* _deviceSend(request, reason: '云端连接失败/超时');
      } else {
        rethrow;
      }
    }
  }

  /// 端侧单发路径：多轮消息压平为单发提取 prompt（§2 端侧职责内的活）。
  ///
  /// 用 StreamController 承载而非裸 async*：async* 的 await 挂起点接不到订阅取消
  /// （Dart Future 不可取消），端侧原生生成会跑到底白烧 CPU/电池；控制器 onCancel
  /// 在取消瞬间同步触发 [OnDeviceLlmEngine.cancelActive]（§10 Abort 级联①步的
  /// 端侧路径）。生成结果为空仍抛 [InferenceException]（经 addError 走流错误，
  /// 与原 async* 语义一致）。
  Stream<CloudStreamEvent> _deviceSend(
    CloudChatRequest request, {
    required String reason,
  }) {
    final device = onDevice!;
    // 已完成标志：stream 正常 done 后 yield* 也会退订（触发 onCancel），
    // 不能把「完成后的正常退订」误判为「取消」——只在未完成时才联动 cancelActive。
    var completed = false;
    late StreamController<CloudStreamEvent> ctrl;
    ctrl = StreamController<CloudStreamEvent>(
      onCancel: () => completed ? Future<void>.value() : device.cancelActive(),
    );
    Future<void>(() async {
      debugPrint('[HybridEngine] 端侧路径（$reason）：${device.name}');
      try {
        final systemParts = <String>[];
        final userParts = <String>[];
        for (final m in request.messages) {
          switch (m) {
            case SystemMessage(:final content):
              systemParts.add(content);
            case UserMessage(:final content):
              userParts.add(content);
            case AssistantMessage(:final content):
              if (content != null) userParts.add(content);
            case ToolResultMessage(:final content):
              userParts.add(content);
          }
        }
        final text = await device.generate(
          userParts.join('\n\n'),
          system: systemParts.isEmpty ? null : systemParts.join('\n\n'),
          maxTokens: request.maxTokens ?? 512,
        );
        if (text == null || text.isEmpty) {
          final why = await device.unavailableReasonAsync();
          throw InferenceException('端侧生成失败（$reason）：${why ?? '空产出'}');
        }
        ctrl.add(CloudTextDelta(text));
        ctrl.add(const CloudDone(finishReason: CloudFinishReason.stop));
      } catch (e) {
        ctrl.addError(e);
      } finally {
        completed = true;
        await ctrl.close();
      }
    });
    return ctrl.stream;
  }
}

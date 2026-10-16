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
  ///
  /// 探测异常按**在线**处理的方向取舍（P2-1 评估后保留）：失败朝向「更丰富的
  /// 路径」——继续尝试云端，云端自有判据（超时/5xx/连接失败）兜底，且其失败
  /// 已经过 P0-2 错误行动卡对用户可见；反向（按离线切端侧）会让用户在云端
  /// 其实可用时静默失去云端能力，同样不可解释。
  Future<bool> _isOffline() async {
    final probe = isOfflineProbe;
    if (probe == null) return false;
    try {
      return await probe();
    } catch (e) {
      // DEGRADE: 探测失败视作在线——方向=朝向更丰富路径，其失败可见（P0-2）。
      debugPrint('[DEGRADE] hybrid-offline-probe: $e');
      return false;
    }
  }

  /// 设备门禁查询（无门禁位 = 放行）。
  ///
  /// 探测异常按**关闸**处理的方向取舍（P2-1 收紧，原为放行）：门禁是设备
  /// 分级兜底（RAM/电量/温控），探针异常时放行 = 在弱设备上跑端侧，风险是
  /// OOM/过热——保守方向应为关闸（与配额篡改「宁可重置不信任被改数据」同
  /// 哲学）。关闸后路由：有云端走云端，否则报「无可用推理引擎」可见错误。
  Future<({bool pass, String reason})> _deviceGate() async {
    final gate = deviceTierGate;
    if (gate == null) return (pass: true, reason: '无门禁位');
    try {
      return await gate();
    } catch (e) {
      // DEGRADE: 门禁探测异常 → fail-closed 关闸（P2-1：原放行方向偏危险）。
      debugPrint('[DEGRADE] hybrid-device-gate: $e');
      return (pass: false, reason: '门禁探测异常，端侧关闸（保守）');
    }
  }

  @override
  String get name => cloud == null
      ? '混合引擎（仅端侧）· ${onDevice?.name ?? '无'}'
      : '混合引擎 · ${cloud!.name}';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) async* {
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
    yield* _cloudSend(
      c,
      request,
      allowDeviceFallback: canDevice,
      onActivity: onActivity,
    );
  }

  Stream<CloudStreamEvent> _cloudSend(
    CloudLlmEngine c,
    CloudChatRequest request, {
    required bool allowDeviceFallback,
    void Function()? onActivity,
  }) async* {
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

      srcSub = c.send(request, onActivity: noteActivity).listen(
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
            yield* _deviceSend(request, reason: '云端空产出（流完成但零可见内容）');
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

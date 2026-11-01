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
import '../llm/on_device_engine.dart';
import '../llm/on_device_pending_load.dart';
import '../llm/on_device_chat_prompt.dart';
import 'degradation_controller.dart';

class HybridCloudEngine implements CloudLlmEngine {
  HybridCloudEngine({
    required this.controller,
    this.cloud,
    this.onDevice,
    this.isOfflineProbe,
    this.deviceTierGate,
    this.deviceToolPolicy,
    this.preferOnDevice = false,
    this.isForegroundProbe,
  }) : _enableCapable = onDevice is OnDeviceEnableCapable
            ? onDevice as OnDeviceEnableCapable
            : null;

  /// 端侧显式加载能力（探测：onDevice 实现 [OnDeviceEnableCapable] 才非 null）。
  /// 首次命中端侧路径前由 [send] 触发 [OnDeviceEnableCapable.enable]，加载过程
  /// 对用户可见；加载失败显式报错、不走云端。
  final OnDeviceEnableCapable? _enableCapable;

  final DegradationController controller;

  /// 云端引擎（null = 未配置 BYOK，仅端侧路径）。
  final CloudLlmEngine? cloud;

  /// 端侧引擎（null = 引擎未挂载/平台不支持）。
  final OnDeviceLlmEngine? onDevice;

  /// 前台态探针（注入；null = 视为后台保守处理）：场景 A/B/C 切云语义拆分——
  /// 场景 B（未加载 + 后台触发）**不切云**，打 PendingForegroundLoad 暂存等
  /// 前台；场景 C（未加载 + 前台发起）加载态 + 超时保护 → 显式失败或按需
  /// 降级云端。探测异常按**后台**处理（宁暂存，不误切云外发数据）。
  final Future<bool> Function()? isForegroundProbe;

  /// 物理断网探测（注入；null = 不探测视作在线）。判据「断网即切」的探测位，
  /// T3 接 Connectivity 实测。
  final Future<bool> Function()? isOfflineProbe;

  /// 设备分级门禁（§16，注入；null = 不门禁）。裁决 (pass, reason)；
  /// 关闸 ≡ 端侧不可用（路由语义与 onDevice=null 一致），reason 留痕可观测。
  final Future<({bool pass, String reason})> Function()? deviceTierGate;

  /// 端侧工具面判据（S2 正式接线，注入；null = 严格 `tools.isEmpty`）。
  ///
  /// §2 端侧硬约束的本意是「需要**云端工具编排**的请求不得走端侧」。但
  /// AgentLoop 的工具面恒定含宿主本地元工具（get_connected_apps / 记忆 /
  /// 资源等，宿主本地拦截执行），按字面 `tools.isEmpty` 纯聊天永远不可端侧。
  /// 注入方（hybrid_assembly）以「tools 全为宿主本地元工具 → 放行」收口——
  /// 端侧单发不产工具调用，元工具静默缺席 = 离线降级的可接受语义。
  final bool Function(List<CloudToolSchema> tools)? deviceToolPolicy;

  /// 用户偏好优先端侧（设置页持久化，默认 false）：即便云端健康也想走端侧；
  /// 门禁关闸 / 引擎死亡仍无缝切云（兜底语义不变）。默认 false = 云端优先，
  /// 避免 1.5B 弱模型在未选时默认降质。
  final bool preferOnDevice;

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

  /// 前台态判定（场景 A/B/C 用）：探针缺省或异常 → 视为后台（保守：宁暂存
  /// 等前台，不误切云外发数据）。
  Future<bool> _isForeground() async {
    final probe = isForegroundProbe;
    if (probe == null) return false;
    try {
      return await probe();
    } catch (e) {
      debugPrint('[DEGRADE] hybrid-foreground-probe: $e');
      return false;
    }
  }

  /// 设备门禁查询（advisory；无门禁位 = 无提示）。
  ///
  /// **2026-10-31 用户裁决：门禁层降级 advisory**——判定结果只留痕提示，
  /// 不参与路由拦截（真保护 = 运行时护栏链，见 send() 内注释）。探测异常
  /// 重探一次仍失败按 unknown 如实留痕；「紧急强行启用」随拦截语义退役。
  Future<({bool pass, String reason, bool unknown})> _deviceGate() async {
    final gate = deviceTierGate;
    if (gate == null) return (pass: true, reason: '无门禁位', unknown: false);
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final r = await gate();
        return (pass: r.pass, reason: r.reason, unknown: false);
      } catch (e) {
        lastError = e;
        debugPrint('[DEGRADE] hybrid-device-gate (attempt $attempt): $e');
      }
    }
    return (
      pass: false,
      reason: '门禁探测异常（重试后仍失败：$lastError），端侧状态未知',
      unknown: true,
    );
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
    // 门禁改 advisory（2026-10-31 用户裁决）：RAM/电量/温控判定只留痕提示，
    // 不拦路——真保护 = 运行时护栏链（:engine 隔离 + EngineDied 切云 + 熔断 +
    // 内存护栏驱逐 + MemGate 起跑闸 + :engine 温控连续确认沿）。误判史多次
    // 实证拦截成本高于收益，「紧急强行启用」随拦截语义一并退役。
    if (!gate.pass) {
      debugPrint('[HybridEngine] [advisory] 门禁不达标（不拦截）：${gate.reason}');
    }
    final toolFaceOk = request.tools.isEmpty ||
        (deviceToolPolicy?.call(request.tools) ?? false);
    final canDevice = toolFaceOk && onDevice != null;
    String? deviceSkipReason;
    if (!canDevice && onDevice != null) {
      // 可观测性（S2 收口）：无云端兜底且端侧被挡时，把挡点随错误透出。
      // 门禁已 advisory 化，不再构成挡点——只剩工具面判据。
      final skips = <String>[
        if (!toolFaceOk) '工具面含云端编排工具（判据不放行）',
        if (onDevice == null) '端侧引擎未挂载',
      ];
      deviceSkipReason = skips.join('；');
      debugPrint('[HybridEngine] 端侧跳过：$deviceSkipReason');
    }
    // 走端侧触发：① 自动（断网 / 云端降级冷却）② 用户偏好优先（云端健康也走）。
    final wantDevice = offline ||
        !controller.shouldUseCloud ||
        preferOnDevice;
    if (canDevice && wantDevice) {
      // 懒加载兜底（用户定调）：首次命中端侧路径才显式加载——bind→就绪→资产→
      // loadModel→数据面 worker，加载过程对用户可见（loadState=loading）。加载
      // 失败显式报错、不走云端（q-1：显式失败不切云）。
      final cap = _enableCapable;
      if (cap != null && cap.loadState.value != OnDeviceLoadState.ready) {
        // 场景 A/B/C 切云语义拆分（2026-10-30 用户裁决）：
        //  A 已加载但运行期夭折 → EngineDiedException 静默无缝切云（见
        //    [_deviceSend] 的引擎死亡分支，本分支不涉及）；
        //  B 未加载冷启动 + **后台**触发 → **不切云、不报错**，打
        //    PendingForegroundLoad 标记（TTL 30min）暂存退出，等下次前台；
        //  C 未加载冷启动 + **前台**用户发起 → 加载态 + 90s 超时保护 →
        //    终态失败显式报错；可自愈类（进程被杀/热降级）按需降级云端。
        final foreground = await _isForeground();
        if (!foreground) {
          await OnDevicePendingLoad.mark();
          debugPrint('[HybridEngine] 场景B：后台冷装载 → 暂存等前台（不切云）');
          throw const InferenceException(
              '端侧模型将在你回到前台时自动加载（后台加载已暂存）');
        }
        try {
          await cap.enable();
        } on OnDeviceLoadException catch (e) {
          // 终态失败（资产缺失 / 设备不支持 / 内存不足）→ q-1 显式报错**不**
          // 切云；可自愈类（`retryable` = 进程/通道中断、热降级 `degraded`）
          // → 切云完成本轮（产出优先 + §5.2 Thermal→Cloud）。
          //
          // 中断类也切云的依据（真机实证 2026-10-30）：`:engine` 被 LMK 连杀
          // 时，等待端侧自愈 = 用户干等 2 分钟以上（退避 3.5/8/12/30/60s 累计），
          // 本轮必须由云端兜底，否则「2 分钟没有首 token」。
          final recoverable = e.degraded || e.retryable;
          if (!recoverable) {
            throw InferenceException('端侧加载失败：${e.reason}');
          }
          final c = cloud;
          if (c == null) {
            throw InferenceException('端侧加载失败：${e.reason}（可稍后重试）');
          }
          debugPrint('[HybridEngine] 场景C：端侧暂不可用（${e.reason}）→ 降级云端完成本轮');
          yield* _cloudSend(c, request,
              allowDeviceFallback: false, onActivity: onActivity);
          return;
        }
      }
      yield* _deviceSend(
        request,
        reason: offline
            ? '物理断网'
            : (preferOnDevice ? '用户偏好优先端侧' : '云端降级冷却期'),
      );
      return;
    }
    final c = cloud;
    if (c == null) {
      if (canDevice) {
        yield* _deviceSend(request, reason: '云端未配置');
        return;
      }
      throw InferenceException(
          '无可用推理引擎：云端未配置且端侧不可用${deviceSkipReason == null ? '' : '（$deviceSkipReason）'}');
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
        yield* _deviceSend(request, reason: '云端流异常中断: $e');
      } else {
        throw CloudNetworkException('云端流异常中断: $e');
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
        // 端侧对话 prompt 构造（2026-10-31 设计修正）：消息序列 JSON（多轮
        // ChatML 由 :engine 模板承载角色）——旧「单发压平 + 文字标注」把
        // assistant 回答塞进 user 轮，违背训练分布 → 复读环（真机定谳）。
        final promptJson = buildOnDeviceChatPromptJson(request.messages);
        debugPrint('[HybridEngine] 端侧对话 prompt：promptJsonChars=${promptJson.length}');
        // P1-6（2026-11-01）：流式契约——逐 delta 投递，消除「收满 512 token
        // 才一次投递」的 30s 无出字缺口。零产出（无事件 close）走下方归因。
        var sawOutput = false;
        await for (final delta in device.generateStream(
          promptJson,
          maxTokens: request.maxTokens ?? 512,
        )) {
          sawOutput = true;
          ctrl.add(CloudTextDelta(delta));
        }
        if (!sawOutput) {
          // 零产出归因（2026-10-30 真机实证「同一对话第二次提问没有输出」）：
          // 端侧**运行时**失败 ≠ 装载失败——q-1 的「显式失败不切云」只约束
          // **装载**失败（用户据此知道「模型没装好」）；此处引擎活着却零产出，
          // 属运行时失败 → **显式上抛并带真因**（既有语义钉「端侧兜底失败 →
          // 上抛（禁静默吞）」不变），但**禁再报笼统「空产出」**：真因（会话
          // 重置失败 / 热降级 / 通道拒绝 / 模型未说话）必须透出，否则用户与
          // 排查者都无从定位「第二轮为什么没有输出」。
          final status = await device.unavailableReasonAsync();
          final aware = device is OnDeviceFailureReasonAware
              ? (device as OnDeviceFailureReasonAware).lastFailureReason
              : null;
          // 引擎就绪时 status 为 null（无失败态）——禁把 null 拼进用户文案
          //（真机实证「端侧生成失败（null）：空产出」不可读）。
          final reason = status ?? '端侧引擎就绪';
          final why = aware ?? status ?? '空产出（模型未产出任何内容）';
          throw InferenceException('端侧生成失败（$reason）：$why');
        }
        ctrl.add(const CloudDone(finishReason: CloudFinishReason.stop));
      } catch (e) {
        if (e is EngineDiedException) {
          // on-device S1-5（总纲 §2）：`:engine` 进程死亡/驱动 Panic 无缝切云，
          // 绝不闪退主进程、绝不让用户会话炸错误卡。切云一次直达（端侧已死，
          // 云端再失败只能原样上抛）。同一 ctrl 承载——§10 取消联动（onCancel →
          // device.cancelActive）保持原直连链不变；无云可切时原样上抛。
          final c = cloud;
          if (c == null) {
            // 云端缺席：EngineDiedException 是内部切云信号，非用户文案——
            // 裸抛会把 'EngineDiedException: ...' 直接上墙（2026-10-31 真机
            // 热闸事故第二症状）。翻译成白话：端侧已中断 + 无兜底的出路提示。
            debugPrint('[HybridEngine] :engine 中断（${e.reason}）但云端未配置 → 白话报错');
            ctrl.addError(InferenceException(
                '端侧已中断且未配置云端兜底（${engineInterruptReason(e)}）——可稍后重试，或配置云端模型后自动切换'));
          } else {
            debugPrint('[HybridEngine] :engine 死亡 → 无缝切云（$reason）');
            try {
              // 切云沿复用 [_cloudSend]（**非裸流**）：继承其自适应看门狗
              // （首 token 死连接判死 + 流内字节活体自适应预算）与空产出
              // 显式报错——裸 `c.send(request)` 无任何兜底，云端一挂即
              // 本轮永挂（真机「第二轮没有任何响应」的另一半成因）。
              await for (final ev
                  in _cloudSend(c, request, allowDeviceFallback: false)) {
                ctrl.add(ev);
              }
            } catch (cloudError) {
              ctrl.addError(cloudError);
            }
          }
        } else {
          ctrl.addError(e);
        }
      } finally {
        completed = true;
        await ctrl.close();
      }
    });
    return ctrl.stream;
  }
}

/// 端侧中断真因白话化（错误卡文案，禁裸露内部异常串）：按 reason 关键字
/// 归类。温控已摘除（2026-10-31 裁决），thermal 分支随之退役。
String engineInterruptReason(EngineDiedException e) {
  final r = e.reason.toLowerCase();
  if (r.contains('busy')) return '引擎正忙（上一轮尚未让出算力）';
  if (r.contains('session') || r.contains('loading')) return '端侧会话未就绪';
  return '引擎中断';
}

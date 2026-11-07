/// 混合引擎端腿（extensibility-hardening S3 自 hybrid_cloud_engine 拆出）：
/// 端侧单发 + 超窗拒绝切云 + EngineDied 无缝切云 + 零产出归因与坏后端记账。
///
/// 用 StreamController 承载而非裸 async*：async* 的 await 挂起点接不到订阅取消
/// （Dart Future 不可取消），端侧原生生成会跑到底白烧 CPU/电池；控制器 onCancel
/// 在取消瞬间同步触发 [OnDeviceLlmEngine.cancelActive]（§10 Abort 级联①步的
/// 端侧路径）。生成结果为空仍抛 [InferenceException]（经 addError 走流错误，
/// 与原 async* 语义一致）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/errors/inference_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/llm.dart';
import '../llm/on_device_admission_probe.dart';
import '../llm/on_device_dispatch_profile.dart';
import '../llm/on_device_engine.dart';
import '../llm/on_device_model_catalog.dart';
import 'capability_router.dart' show onDeviceInputOverflows;
import 'hybrid_cloud_leg.dart';
import 'hybrid_route_probes.dart';

class HybridDeviceLeg {
  HybridDeviceLeg({
    required this.cloudLeg,
    required this.cloud,
    required this.device,
    required this.devicePromptOf,
    required this.cloudForbidden,
    required this.readSelectedModel,
  });

  /// 云腿（EngineDied / 超窗拒绝沿切云复用——继承其自适应看门狗与空产出
  /// 显式报错，裸 `cloud.send(request)` 无任何兜底）。
  final HybridCloudLeg cloudLeg;

  /// 云端引擎（null = 未配置 BYOK，切云沿显式失败）。
  final CloudLlmEngine? cloud;

  /// 端侧引擎（调用方保证非空——本腿仅在端侧可用时进入）。
  final OnDeviceLlmEngine device;

  /// 端侧载荷构造单源（buildDevicePrompt，禁二次估法）。
  final Future<HybridDevicePrompt> Function(
    CloudChatRequest request, {
    OnDeviceModelOption? selected,
  }) devicePromptOf;

  /// 排除位守卫单点（S14e K10）。
  final bool Function(CloudChatRequest request) cloudForbidden;

  /// 选中模型读取口（crash 归因记账用）。
  final Future<OnDeviceModelOption?> Function() readSelectedModel;

  /// 端侧单发路径：多轮消息压平为单发提取 prompt（§2 端侧职责内的活）。
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    required String reason,
    HybridDevicePrompt? prompt,
  }) {
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
        // 端侧对话 prompt 构造与载荷估算（buildDevicePrompt 单源）：消息序列 JSON
        // 由 :engine 侧 ChatML 模板承载角色；历史预算按选中模型窗口动态推导，
        // 策略挂模型本身（默认 ⓪ 真裸 = 仅最新 user 轮）。主入口已构造时复用，
        // 云端兜底等旁路自行构造——两处口径恒等，禁二次估法。
        final prepared = prompt ?? await devicePromptOf(request);
        final promptJson = prepared.promptJson;
        final selected = prepared.selected;
        debugPrint('[HybridEngine] 端侧对话 prompt：promptJsonChars=${promptJson.length}'
            ' contentChars=${prepared.contentChars}');
        // P1-5 输入零预算预检（机制审计，设计定稿 2026-11-01）：**拒绝优先**——
        // 预检超窗显式报错切云（产出优先），设备路径禁第二套截断（阶梯截断 =
        // 上下文治理唯一机制，归 stepped-pruning draft）。预算来源 = 资产面
        // 声明 contextTokens（modelProfile 单源）；未标注（GenieX 系）跳过
        // 预检——其历史字符预算机制（kOnDeviceHistoryCharBudget）在场兜底，
        // 硬编码默认窗口会误拒正常多轮对话。
        // [Fact] 超窗 SDK 行为实证（Qwen 真机轮 2026-11-04，Ace 6）：GenieX
        // llama_cpp 系超窗 = SDK 抛「Input prompt too long」RuntimeException
        // **硬失败**，:engine 捕获转 [DEGRADE]，Dart 侧表现为空产出干净闭合
        // （bytesIn=0/chunks=1，非尾部截断、非进程崩溃）——预检缺席时生产侧
        // 空产出显式报错路径兜底（2026-10-30 已收口），用户可见不静默。
        // GenieX 系无预检沿用现状成立。
        // 判据 = 裁剪后实际载荷（+64 JSON 脚手架）+ 输出预留；按裁剪前原始
        // 消息算会把长 system/历史误当 payload，1280 窗口 1B bundle 每轮误拒
        //（2026-11-04 真机回归）。单轮超 builder 预算仍是唯一真溢出源。
        final ctxTokens = selected?.contextTokens;
        if (ctxTokens != null) {
          final outputReserve = request.maxTokens ?? 512;
          if (onDeviceInputOverflows(
            contentChars: prepared.contentChars,
            outputReserve: outputReserve,
            windowTokens: ctxTokens,
          )) {
            throw OnDeviceContextOverflowException(
                ctxTokens, prepared.contentChars + outputReserve + 64);
          }
        }
        // P1-6（2026-11-01）：流式契约——逐 delta 投递，消除「收满 512 token
        // 才一次投递」的 30s 无出字缺口。零产出（无事件 close）走下方归因。
        // S1 采样下发链（2026-11-03）：meta recommendedSampling 在场则请求级
        // 覆盖引擎内建默认（§3.5 单字段单源，null 字段不覆盖）。
        final sampling = selected?.recommendedSampling;
        var sawOutput = false;
        await for (final delta in device.generateStream(
          promptJson,
          maxTokens: request.maxTokens ?? 512,
          temperature: sampling?.temperature,
          topP: sampling?.topP,
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
          // I6 归因防护（2026-11-05）：归因时引擎**非就绪**（已被驱逐/状态未知/
          // 通道异常）＝零产出不可信为模型缺陷——按会话死亡语义抛 EngineDied
          // （catch 分支无缝切云，产出优先），**禁记 zeroOutput**：否则一次性
          // 基础设施事件被持久化成坏后端记忆，下轮无故跳开端侧。
          if (status != null) {
            throw EngineDiedException(
                'session not ready at empty-output attribution ($status)');
          }
          // DispatchProfile 写入（设计稿 §7，写入单点 = 本方法）：运行时零产出 →
          // 标观测后端 EXCLUDED，下轮查表直跳（#4 坏后端记忆并入画像）。
          // （走到此处引擎必就绪：模型真没说话，归因可信。）
          await _recordBackendExcluded(selected, BackendReason.zeroOutput);
          throw InferenceException('端侧生成失败（$reason）：$why');
        }
        ctrl.add(const CloudDone(finishReason: CloudFinishReason.stop));
      } catch (e) {
        if (e is OnDeviceContextOverflowException) {
          // P1-5 拒绝路径（设计 ②「拒绝优先」）：超窗 = 可自愈（换云端产出），
          // 非终态失败——显式报错并切云（产出优先）；不进运行时坏后端记账
          // （超窗是请求形状问题，非设备/后端缺陷）。
          debugPrint('[HybridEngine] 端侧输入超窗（~${e.estimateTokens}/'
              '${e.windowTokens} tokens）→ 拒绝并切云');
          final c = cloud;
          if (cloudForbidden(request)) {
            // 排除位守卫（S14e）：拒绝优先 = 切云保产出；本步声明禁止云端
            // → 显式失败不切云（超窗数据不出境）。
            ctrl.addError(InferenceException(
                '输入超出端侧模型上下文窗口（约 ${e.windowTokens} tokens），'
                '且本步声明禁止云端（不切云）——请缩短当前输入后重试'));
          } else if (c == null) {
            ctrl.addError(InferenceException(
                '输入超出端侧模型上下文窗口（约 ${e.windowTokens} tokens）且未配置'
                '云端兜底——请缩短当前输入，或配置云端模型后自动切换'));
          } else {
            try {
              await for (final ev
                  in cloudLeg.send(c, request, allowDeviceFallback: false)) {
                ctrl.add(ev);
              }
            } catch (cloudError) {
              ctrl.addError(cloudError);
            }
          }
        } else if (e is EngineDiedException) {
          // DispatchProfile 写入（设计稿 §7）：运行时崩溃/死亡 → 标 EXCLUDED，
          // 下轮查表直跳（同 #4 坏后端记忆并入画像）；eviction 生命周期分码
          // 归因过滤内聚在 [_recordBackendExcluded]。
          await _recordBackendExcluded(await readSelectedModel(),
              BackendReason.crash, diedReason: e.reason);
          // on-device S1-5（总纲 §2）：`:engine` 进程死亡/驱动 Panic 无缝切云，
          // 绝不闪退主进程、绝不让用户会话炸错误卡。切云一次直达（端侧已死，
          // 云端再失败只能原样上抛）。同一 ctrl 承载——§10 取消联动（onCancel →
          // device.cancelActive）保持原直连链不变；无云可切时原样上抛。
          final c = cloud;
          if (cloudForbidden(request)) {
            // 排除位守卫（S14e）：引擎死亡原语义 = 无缝切云（保产出）；本步
            // 声明禁止云端 → 显式失败不切云（数据不出境）。
            debugPrint('[HybridEngine] :engine 死亡且本步禁止云端 → 显式失败');
            ctrl.addError(InferenceException(
                '端侧已中断且本步声明禁止云端（不切云）——可稍后重试，或改用'
                '不禁止云端的步骤声明'));
          } else if (c == null) {
            // 云端缺席：EngineDiedException 是内部切云信号，非用户文案——
            // 裸抛会把 'EngineDiedException: ...' 直接上墙（2026-10-31 真机
            // 热闸事故第二症状）。翻译成白话：端侧已中断 + 无兜底的出路提示。
            debugPrint('[HybridEngine] :engine 中断（${e.reason}）但云端未配置 → 白话报错');
            ctrl.addError(InferenceException(
                '端侧已中断且未配置云端兜底（${engineInterruptReason(e)}）——可稍后重试，或配置云端模型后自动切换'));
          } else {
            debugPrint('[HybridEngine] :engine 死亡 → 无缝切云（$reason）');
            try {
              // 切云沿复用 [cloudLeg.send]（**非裸流**）：继承其自适应看门狗
              // （首 token 死连接判死 + 流内字节活体自适应预算）与空产出
              // 显式报错——裸 `c.send(request)` 无任何兜底，云端一挂即
              // 本轮永挂（真机「第二轮没有任何响应」的另一半成因）。
              await for (final ev
                  in cloudLeg.send(c, request, allowDeviceFallback: false)) {
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

  /// EngineDied 收口时的坏后端记账（**写入单点**——零产出与 crash 两沿共用，
  /// 归因过滤内聚：eviction 生命周期分码不记 crash）。
  Future<void> _recordBackendExcluded(
    OnDeviceModelOption? selected,
    BackendReason reason, {
    String diedReason = '',
  }) async {
    if (reason == BackendReason.crash && evictionLifecycleDied(diedReason)) {
      // 归因过滤（2026-11-05，与 I6 收敛去歧义配套）：**在途被驱逐打断**
      //（SESSION_ABORTED_BY_EVICTION）、数据面 EOF（驱逐关闭数据面）与
      // **装载未完成类可重试分码**（session_loading 装载慢被打断 /
      // session_epoch_mismatch 票据过期 / session_model_mismatch 资产变更
      // ——均为可自愈中断，真机实证 14:38 装载 100s 超窗被打断被记成
      // GPU crash）不是后端缺陷——记 crash 会把正常生命周期/环境事件持久
      // 化成坏后端记忆，下轮无故跳开端侧。真进程死亡/看门狗/死锁类照记。
      return;
    }
    await recordRuntimeBackendExcluded(selected, reason);
  }
}

/// EngineDied 归因过滤（2026-11-05 与 I6 收敛去歧义配套）：**在途被驱逐打断**
///（SESSION_ABORTED_BY_EVICTION）、数据面 EOF（驱逐关闭数据面）与**装载未完成
/// 类可重试分码**（session_loading 装载慢被打断 / session_epoch_mismatch 票据
/// 过期 / session_model_mismatch 资产变更——均为可自愈中断）不是后端缺陷——
/// 记 crash 会把正常生命周期/环境事件持久化成坏后端记忆，下轮无故跳开端侧。
/// 真进程死亡/看门狗/死锁类照记。S3 特征钉 = hybrid_send_golden_test。
bool evictionLifecycleDied(String diedReason) {
  final r = diedReason.toLowerCase();
  return r.contains('session_aborted_by_eviction') ||
      r.contains('data plane eof') ||
      r.contains('session_loading') ||
      r.contains('session_epoch_mismatch') ||
      r.contains('session_model_mismatch');
}

/// 端侧中断真因白话化（错误卡文案，禁裸露内部异常串）：按 reason 关键字
/// 归类。温控已摘除（2026-10-31 裁决），thermal 分支随之退役。
String engineInterruptReason(EngineDiedException e) {
  final r = e.reason.toLowerCase();
  // S14e（K11）：协作式打断未生效 = 等待窗口耗尽且在途生成可能仍在跑，
  // 算力仍被占——不得表述为「已腾出/已打断」。
  if (r.contains('interrupt_not_effective') ||
      r.contains('interrupt not effective')) {
    return '端侧算力正被占用，协作式打断未生效（算力尚未让出）';
  }
  if (r.contains('busy')) return '引擎正忙（上一轮尚未让出算力）';
  if (r.contains('session') || r.contains('loading')) return '端侧会话未就绪';
  return '引擎中断';
}

/// P1-5 端侧输入超窗拒绝（机制审计，设计定稿 2026-11-01）：预检超窗即抛，
/// 拒绝优先——设备路径禁第二套截断，拒绝沿切云保产出。携带窗口与估算值
/// 供日志/文案归因。
class OnDeviceContextOverflowException implements Exception {
  OnDeviceContextOverflowException(this.windowTokens, this.estimateTokens);

  final int windowTokens;
  final int estimateTokens;

  @override
  String toString() =>
      '端侧输入超窗: ~$estimateTokens tokens > window $windowTokens';
}

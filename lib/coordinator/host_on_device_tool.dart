/// 端侧供给面对外导出执行器（task-capability W5 · 端侧供给面对外导出）。
///
/// **导出项**：`on_device_complete`——外部调用方（PC 经聚合网关）经 `host__`
/// 命名空间使用宿主端侧算力做轻量单发推理。
///
/// **降级语义声明（对外可知，红线：转发方接受降级语义需显式可知）**：
/// - 端侧算力**尽力而为**：未装载/降级窗口/PII 拦截/空产出均以错误结果
///   返回（`isError: true`，content 含原因），**宿主侧不自动兜底云端**——
///   调用方须自行处置失败（重试或自有降级）；
/// - 幂等无副作用（K20：单轮自足，不驱动工具往返、不触发装载）；
/// - 失败原因分类对调用方可读（未就绪/降级窗口/PII 拦截/产出为空）。
///
/// **主体与配额**：allowedActors 见 Allowlist 登记项；调用方身份维度配额
/// （W5 后续条目）经 HybridCloudEngine.quotaChecker 注入位生效，本执行器
/// 直连供给面原语，不承担配额裁决。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../llm/cloud/cloud_llm.dart';
import '../llm/on_device_capability.dart';
import 'agent_loop.dart';
import 'caller_death_interrupt.dart';
import 'supply_quota.dart';

/// 端侧供给面导出执行器。
class HostOnDeviceToolExecutor implements ToolExecutor {
  HostOnDeviceToolExecutor(this._primitive, {this.quota, this.callerKey});

  final OnDeviceCapabilityService _primitive;

  /// 调用方配额（W5；null = 未装配不裁决——既有装配零行为变化）。
  /// 事务语义（K22）：并发 acquire/release 恒配对（try/finally）；频次仅
  /// 在开始产出时计入；被动切云不扣（导出面 failFast 无切云）。
  final SupplyQuota? quota;

  /// 调用方身份键（W5 死亡联动；Binder 路径 = 插件包名，per-face 实例注入；
  /// null = 不注册打断——既有装配/网关工具面零行为变化）。
  final String? callerKey;

  /// 工具名（裸名，与本机 executor 一致，不带 `host__` 前缀）。
  static const toolName = 'on_device_complete';

  /// Binder 路径私有反向 method（Tier 1 契约，2026-11-04）：同机插件 App 经
  /// 反向请求转发宿主端侧算力——与 `host__on_device_complete` 工具面同参数
  /// 语义 {instruction, input}、同 result 形（{role, model, content}）、同源
  /// 执行器（K22 配额 + 降级语义单源）。method 名单源于此（reverse_wiring
  /// 分派消费），禁双源漂移。
  static const reverseMethodName = 'host/onDeviceComplete';

  /// 工具声明（§5.1 描述主动引导：写「怎么用才对」+ 降级语义显式声明）。
  static List<CloudToolSchema> toolSchemas() => [
        CloudToolSchema(
          name: toolName,
          description: '使用宿主端侧小模型做轻量单发推理（提取/摘要/改写类短任务）。'
              '怎么用才对：instruction 写清任务与输出要求（如「从下文提取地点列表，'
              '仅输出 JSON 数组」），input 放待处理原文；适合几百字以内的短文本，'
              '长文请分段。降级语义（调用前须知）：端侧算力尽力而为——模型未装载、'
              '降级窗口或隐私拦截时返回错误（content 含原因），宿主不自动兜底云端，'
              '调用方须自行处置失败；结果幂等无副作用，重复调用只是重新推理。',
          parametersSchema: {
            'type': 'object',
            'properties': {
              'instruction': {
                'type': 'string',
                'description': '任务指令（做什么、输出什么形状）',
              },
              'input': {
                'type': 'string',
                'description': '待处理的原文',
              },
            },
            'required': ['instruction', 'input'],
          },
        ),
      ];

  /// 端侧单发 + 调用方死亡联动：经 [OnDeviceInterruptible.completeInterruptible]
  /// 聚合（S18c 契约——complete 的流式形态），订阅期间经 [CallerDeathInterrupt]
  /// 注册打断回调；调用方死亡 → 订阅取消（透传 cancel(requestId) 引擎让槽）
  /// → 返回 null（作废）。
  ///
  /// **语义同源**：走原语的**可中断聚合**而非自建流聚合——降级三档 / 失败
  /// 计数 / 空产出判定与 `complete` 同一份实现（禁双源：自建聚合会绕过
  /// [_degrade] 收口，丢失失败计数与降级档）。
  ///
  /// **打断是协作式（K11）**：中断只在生成循环检查点生效，打断未生效时**不得
  /// 假设算力已腾出**——本方法不重启引擎（重启即冷装载）、不切云（导出面
  /// failFast 语义：宿主不兜底云端），引擎侧终态自收。
  Future<String?> _completeWithDeathInterrupt(
    String instruction,
    String input,
    String callerKey,
  ) async {
    final interrupt = callerDeathInterruptSingleton;
    final primitive = _primitive;
    // 可中断聚合能力（可选接口）——不支持则走退化路径。
    // 显式 cast（禁依赖流提升：interface class 的提升结果可能落成 Never，
    // 那样真机路径会静默退化成「无打断能力」）。
    final OnDeviceInterruptible? interruptible =
        primitive is OnDeviceInterruptible
            ? primitive as OnDeviceInterruptible
            : null;
    if (interrupt == null || interruptible == null) {
      // 退化路径（注册表未接线 / 实现不支持可中断聚合）：走 complete()——
      // 语义与完整路径同口径，只是**无打断能力**（K17 在该形态下不生效，
      // 属能力缺失而非静默降级）。
      return primitive.complete(
        instruction: instruction,
        input: input,
        fallback: PrimitiveFallbackPolicy.failFast,
        traceId: 'host_export',
      );
    }
    void Function()? unregister;
    try {
      return await interruptible.completeInterruptible(
        instruction: instruction,
        input: input,
        fallback: PrimitiveFallbackPolicy.failFast,
        traceId: 'host_export',
        onSubscribed: (cancel) {
          // 注册打断回调（订阅建立即注册——注册窗口在订阅内，外部打断自此
          // 可让槽；漏注册 = 漏打断 = 孤儿算力空跑）。
          unregister = interrupt.register(callerKey, () async {
            await cancel(); // 取消订阅 → 引擎 cancel(requestId) 让槽
          });
        },
      );
    } on OnDeviceInterruptedException {
      // 打断生效 → 本次调用作废（产出即弃，不回程；调用方已死）。
      return null;
    } finally {
      unregister?.call(); // 幂等注销（正常收尾/死亡打断两路）
    }
  }

  /// schema 原文解析（供 `HostSchemaResolver` 合成 `tools/list` 用；owner =
  /// 执行面单源，与 `HostStatusToolExecutor.schemaOf` 同型）。
  static Map<String, Object?> schemaOf(String tool) => tool == toolName
      ? <String, Object?>{
          'description': toolSchemas().single.description,
          'inputSchema': toolSchemas().single.parametersSchema,
        }
      : const <String, Object?>{};

  /// [callerKeyOverride] = S07b 平台侧已解析的调用方包名（内核 UID 推导，
  /// Binder 反向路径传入）：优先于实例 [callerKey]（transport 元数据）——
  /// 配额记账与死亡打断按内核身份裁决（主体可辨）。缺省 null = 既有行为。
  @override
  Future<ToolExecutionResult> execute(
    AssembledToolCall call, {
    String? callerKeyOverride,
  }) async {
    if (call.name != toolName) {
      // 非本工具裸名透传兜底（与 HostStatusToolExecutor 同构：装配链约定）。
      return const ToolExecutionResult(
          content: 'on_device_complete 执行器不接受其他工具名', isError: true);
    }
    final Object? args;
    try {
      args = jsonDecode(call.argumentsJson);
    } on FormatException catch (e) {
      return ToolExecutionResult(
          content: '参数不是合法 JSON: $e', isError: true);
    }
    if (args is! Map) {
      return const ToolExecutionResult(
          content: '参数必须是 JSON 对象', isError: true);
    }
    final instruction = args['instruction'];
    final input = args['input'];
    if (instruction is! String || instruction.trim().isEmpty) {
      return const ToolExecutionResult(
          content: '缺少 instruction（任务指令）', isError: true);
    }
    if (input is! String) {
      return const ToolExecutionResult(
          content: '缺少 input（待处理原文）', isError: true);
    }
    // 逐调用留痕（debug 桥取证）：[AI-CAP] 行进 AppLog（debugPrint 自动捕获）
    // ——PC 侧经 host__on_device_complete 的每次承接，宿主侧留调用方/耗时/产出。
    final sw = Stopwatch()..start();
    final caller = callerKeyOverride ?? callerKey ?? 'unknown';
    void capLog(String outcome) =>
        debugPrint('[AI-CAP] caller=$caller skill=on_device_complete '
            'engine=on-device ms=${sw.elapsedMilliseconds} $outcome');
    try {
      // K22 事务语义收口：并发占用 → 频次预检（产出前）→ 产出 → 计入 →
      // finally 释放（无论成败一律让槽）。频次仅在实际开始产出时计入
      // （complete 成功返回）；受理段/推理失败不计。
      final quota = this.quota;
      if (quota != null && !quota.acquire()) {
        capLog('deny=concurrency');
        return const ToolExecutionResult(
          content: '端侧算力并发已达上限（稍后重试）',
          isError: true,
        );
      }
      try {
        if (quota != null) {
          final denial = quota.checkFrequency(DateTime.now());
          if (denial != null) {
            capLog('deny=frequency retryAfter=${denial.inSeconds}s');
            return ToolExecutionResult(
              content: '端侧算力频次超限（滑动窗口次数制），'
                  '建议 ${denial.inSeconds}s 后重试',
              isError: true,
            );
          }
        }
        // failFast 直通：降级语义 = 失败对调用方显式可见（宿主不兜底云端，
        // 红线「转发方接受降级语义需显式可知」的执行面承载）。
        // W5 死亡联动：[callerKey] 非空时注册打断回调——调用方进程死亡 →
        // 协作式打断（completeStream 订阅取消 → 透传 cancel(requestId) 让槽）
        // 并作废本次调用（产出即弃，调用方已死不回程）。缺省 null = 不注册
        // （既有装配零行为变化）。
        final callerKey = callerKeyOverride ?? this.callerKey;
        if (callerKey == null) {
          final out = await _primitive.complete(
            instruction: instruction,
            input: input,
            fallback: PrimitiveFallbackPolicy.failFast,
            traceId: 'host_export',
          );
          capLog('ok outChars=${out.length}');
          quota?.countOutput(DateTime.now()); // 实际产出 → 频次计入
          return ToolExecutionResult(content: out);
        }
        final result = await _completeWithDeathInterrupt(
            instruction, input, callerKey);
        if (result == null) {
          // 调用方死亡作废：不扣频次（未产出交付）、执行槽经 finally 释放。
          capLog('aborted=caller-death');
          return const ToolExecutionResult(
              content: '调用方已断开，本次端侧调用已作废', isError: true);
        }
        capLog('ok outChars=${result.length}');
        quota?.countOutput(DateTime.now()); // 实际产出 → 频次计入
        return ToolExecutionResult(content: result);
      } finally {
        quota?.release(); // 退出无论成败一律释放执行槽占用
      }
    } on OnDevicePrimitiveException catch (e) {
      capLog('err: ${e.message}');
      return ToolExecutionResult(
          content: '端侧推理失败（宿主不兜底云端，可重试或自行降级）：${e.message}',
          isError: true);
    }
  }
}

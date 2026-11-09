/// 反向能力接线共享件（施工稿 §S2 二期：消装配第二副本）。
///
/// 此前「每个 client 接管 sampling 反向请求」的循环在 `McpRuntime._assembleInner`
/// 与 `GatewayController._assemble` 各有一份——语义相同（按 face 遍历、包
/// `onSamplingBegin/End`、host 面除外），实现漂移风险即第二副本债。
/// 收口为唯一实现，两处调用；差异只允许出现在参数（排除集 / 回调）。
///
/// 纪律：本件纯 Dart；elicitation / CoW 属 chat 专属接线（profile 已关闸），
/// **不**进本件——它们在 `_assembleInner` 内由 `capabilitiesFor(profile)` 驱动。
library;

import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart' show debugPrint;

import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/sampling_engine.dart' show CloudSamplingEngine;
import '../core/errors/mcp_error.dart';
import '../llm/on_device_capability.dart';
import '../mcp/mcp_client.dart';
import '../mcp/sampling.dart' show SamplingQuota, samplingRequestHandler;
import '../mcp/transport/binder_transport.dart';
import 'ai_complete_service.dart';
import 'caller_death_interrupt.dart';
import 'host_on_device_tool.dart';
import 'supply_quota.dart';
import 'supply_task_pool.dart';
import 'mcp_tool_face.dart';

/// 逐 face 接线 sampling 反向请求（serverKey = serverId）。
///
/// [excludedServerIds]：不供给反向请求的面（网关传 `kHostServerId`——host 面
/// 是宿主自身导出面，不回调宿主推理）。
///
/// **端侧算力反向请求（收编后形态）**：推理入口 = 标准原语 **`ai/complete`**
///（`AiCompleteService` 统一受理链，2026-11-09 收编迁移）；私有 method
/// `host/onDeviceComplete` **已退役**（响应已删，旧调用回 -32601——退役钉）；
/// 拉取面 `host/onDeviceTaskStatus` 保留（Pull = 交付真理源）。sampling 云端
/// 反向请求不受影响（D2 保留兼容）。
///
/// **W5 调用方进程死亡联动打断（K17）**：本件是反向路径的装配单点——首次
/// 装配即挂上调用方死亡注册表（[ensureCallerDeathInterruptWired]，幂等单例），
/// 平台侧独立死亡代理推来的 `onCallerDied` 事件据此打断该调用方名下在途的
/// 端侧执行并作废本次调用。
void wireSampling({
  required Map<String, McpToolFace> faces,
  required CloudLlmEngine engine,
  required SamplingQuota quota,
  Set<String> excludedServerIds = const <String>{},
  void Function()? onSamplingBegin,
  void Function()? onSamplingEnd,
  OnDeviceCapabilityService? onDeviceCapability,
  SupplyQuota? supplyQuota,
  AppCapabilityRegistry? capabilityRegistry,
  AiAuditSink? auditSink,
  CallerForegroundProbe? foregroundProbe,
  SupplyTaskPool? taskPool,
}) {
  // K17 装配接线（幂等单例；两装配点经本共享件同款调用，消第二副本）。
  ensureCallerDeathInterruptWired();
  // M-B 统一受理链装配（ensureConfigured 只填空腿——两装配点携带件不对称，
  // 后装点覆盖会拆掉先装腿；D2 收敛：sampling 壳与 ai/complete 共用同链）。
  // M-C：能力档案注册表 / ops 审计 / 前台探针同槽注入（null = 未装配零变化）。
  // 收编（0.5.0）：deferred 任务池同槽——ai/complete 冷态联合态承载。
  AiCompleteService.ensureConfigured(
    onDevice: onDeviceCapability,
    cloudEngine: CloudSamplingEngine(engine),
    quota: supplyQuota,
    capabilityRegistry: capabilityRegistry,
    auditSink: auditSink,
    foregroundProbe: foregroundProbe,
    taskPool: taskPool,
  );
  for (final entry in faces.entries) {
    if (excludedServerIds.contains(entry.key)) continue;
    // D2 适配壳核心注入：sampling 反向请求经统一受理链（AiCompleteFailure
    // → McpRpcException(-32000) error 帧映射在此收口——mcp 域不感知
    // coordinator 类型，跨界只走纯值函数 + 标准异常）。
    final sampling = samplingRequestHandler(
      engine: CloudSamplingEngine(engine),
      quota: quota,
      serverKey: entry.key,
      completeCore: ({
        required String instruction,
        required String input,
        int? maxTokens,
        double? temperature,
      }) async {
        try {
          final c = await AiCompleteService.instance.completeCore(
            instruction: instruction,
            input: input,
            maxTokens: maxTokens,
            temperature: temperature,
          );
          return (text: c.text, model: c.model);
        } on AiCompleteFailure catch (e) {
          throw McpRpcException(-32000, e.message, data: <String, Object?>{
            'status': e.status,
            if (e.retryAfterMs != null) AiWire.keyRetryAfterMs: e.retryAfterMs,
          });
        }
      },
    );
    // W5 Binder 路径：端侧算力转发处理器（非空才挂；与导出工具面同源执行器
    // ——降级语义/K22 配额单源，禁双实现漂移）。per-face 实例携带调用方身份
    // 键（callerKey = 调用方身份键，见 [_callerIdentityOf]；死亡联动按此打断）；
    // quota 共享实例（频次/并发全局记账正确）。
    final HostOnDeviceToolExecutor? supplyExport =
        onDeviceCapability == null
            ? null
            : HostOnDeviceToolExecutor(
                onDeviceCapability,
                quota: supplyQuota,
                callerKey: _callerIdentityOf(entry.value),
                // W6-a 入池接线（2026-11-08 联调缺陷修复）：此前反向路径未挂池 →
                // allow_deferred 永远不入池，冷态只能同步报错。池为宿主驻留单例
                // （同文件下方任务状态执行器同款用法）；仅 allow_deferred=true
                // 时生效，存量 failFast 语义零变化。
                taskPool: SupplyTaskPool.instance,
              );
    // S07/S07b：Binder 面走携带平台侧已解析身份的钩子（帧未携带身份 = 平台侧
    // 解析失败，由传输层按拒绝处置 -32001，本处理器只消费已解析身份）；
    // 非 Binder 面（HTTP）无内核身份，维持既有钩子零变化。
    Future<Map<String, Object?>?> handle(
      String method,
      Object? params,
      ResolvedCallerIdentity? caller,
    ) async {
      debugPrint('[reverse] handle method=$method supplyExport=${supplyExport != null}');
      // 退役清账（2026-11-09）：私有 method `host/onDeviceComplete` 已删响应
      //（goodshare 消费面已迁 `ai/complete`——见 ai_complete_service 收编分支），
      // 旧调用落 sampling handler 的 -32601（未知反向请求）；退役钉
      // = reverse_wiring_test「host/onDeviceComplete 退役」。
      if (method == HostSupplyTaskStatusExecutor.reverseMethodName) {
        return forwardSupplyTaskStatus(params,
            callerKeyOverride: caller?.packageName);
      }
      onSamplingBegin?.call();
      return sampling(method, params).whenComplete(() => onSamplingEnd?.call());
    }

    final transport = entry.value.client.transport;
    // S1c 能力化：按 [CallerIdentityTransport] 接口探测，禁 is 具体类——新传输
    // 具备平台侧身份解析能力即实现该接口，本接线零改动。
    if (transport is ReverseSessionTransport) {
      // M-B 反向会话钩子（多帧应答）：ai/complete + ai/cancel 直达统一受理链
      //（_async ack + _meta.phase progress + 终帧全走 answerReverse 同 id 多次
      // 透传）；其余 method 委托既有 handle() 并复制单帧应答语义（与 transport
      // _reverseFrame 等价——result/error/异常三态，禁在两处各拼一份帧序）。
      transport.onServerRequestSessionWithCaller =
          (method, id, params, caller, emit) async {
        final handled = await AiCompleteService.instance.handleAiMethod(
          method: method,
          id: id,
          params: params,
          caller: caller,
          callerKeyFallback: _callerIdentityOf(entry.value),
          emit: emit,
        );
        if (handled) return;
        try {
          final r = await handle(method, params, caller);
          emit(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': r});
        } on McpRpcException catch (e) {
          emit(<String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, Object?>{
              'code': e.code,
              'message': e.message,
              if (e.data != null) 'data': e.data,
            },
          });
        } catch (e) {
          emit(<String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, Object?>{
              'code': -32603,
              'message': '宿主反向请求处理失败: $e',
            },
          });
        }
      };
    } else if (transport is CallerIdentityTransport) {
      transport.onServerRequestWithCaller = (method, params, caller) =>
          handle(method, params, caller);
    } else {
      entry.value.client.onServerRequest = (method, params) =>
          handle(method, params, null);
    }
  }
}

/// 调用方身份键（**与平台侧死亡事件键同源**，K17）：
///
/// Binder 路径 = 目标插件**包名**（物理主键 §9.3）——平台侧新增死亡代理推的
/// `callerKey` 即包名；非 Binder 面（HTTP 插件）无 Binder 死亡代理，回退
/// [McpToolFace.serverId]（该路无死亡事件，键不匹配也无副作用）。
///
/// **红线**：禁直接用 face map 的 key（serverId）——serverId 与包名**不同值**
/// （'goodshare' vs 'com.zzh.goodshare'），混用即死亡通知匹配不上，打断
/// 静默失效（= 孤儿算力空跑，K17 目标落空）。
String _callerIdentityOf(McpToolFace face) {
  final transport = face.client.transport;
  if (transport is CallerIdentityTransport) return transport.callerKey;
  return face.serverId;
}

/// host/onDeviceTaskStatus 反向请求转发（W6-a 拉取接缝）：Pull = 交付
/// 真理源——pendingDelivery 查询即置 delivered 回结果；M5 身份过滤。
Future<Map<String, Object?>?> forwardSupplyTaskStatus(
    Object? params,
    {String? callerKeyOverride}) async {
  final p = params is Map<String, Object?> ? params : <String, Object?>{};
  final taskId = p['task_id'] as String?;
  if (taskId == null || taskId.isEmpty) {
    throw McpRpcException(-32000, '缺少 task_id');
  }
  if (callerKeyOverride == null || callerKeyOverride.isEmpty) {
    throw McpRpcException(-32000, '调用方身份不可辨（M5：无内核身份不受理）');
  }
  final entry = await SupplyTaskPool.instance
      .statusFor(taskId, callerKey: callerKeyOverride);
  if (entry == null) {
    return {'role': 'assistant', 'model': 'goodhub-on-device',
        'content': {'type': 'text',
            'text': jsonEncode({'task_id': taskId, 'status': 'not_found'})}};
  }
  if (entry.status == SupplyTaskStatus.pendingDelivery) {
    await SupplyTaskPool.instance.markDelivered(taskId,
        callerKey: callerKeyOverride);
  }
  return {'role': 'assistant', 'model': 'goodhub-on-device',
      'content': {'type': 'text', 'text': jsonEncode(entry.projection())}};
}

/// 端侧反向请求驻留接线（W6-a 共享件，2026-11-08 联调缺陷 C 修复）。
///
/// **缺口**：反向路径此前只在网关装配（[GatewayController._assemble]）与聊天
/// 装配（`_assembleInner`，caps.sampling 门控）接线；驻留场景（冷启动 +
/// task-consume 常驻，无聊天无网关）两路都不触发——goodshare 的反向帧经其
/// task-consume client 的 Binder 传输到达，却无 handler 应答，恒 `result:null`
/// （真机实证 07:25/07:33：`withCaller=false` → `{"id":"srv_N","result":null}`，
/// goodshare 侧判「宿主未连入」）。
///
/// 本件把端侧拉取面 Tier 1 反向 method（`host/onDeviceTaskStatus`）注册到
/// **指定 client 的传输**——与 [wireSampling] 同款 S1c 身份探测；推理入口
/// `ai/complete` 由同一传输的会话钩子承载（[AiCompleteService]，收编后形态）。
/// **sampling 云端不外借**：非端侧 method 回 null（驻留场景无人值守路径不外借
/// 宿主推理资源，对齐 _assembleInner 纪律）。
void wireOnDeviceReverse({
  required McpClient client,
  required OnDeviceCapabilityService onDeviceCapability,
  required String callerKey,
  SupplyQuota? supplyQuota,
  AppCapabilityRegistry? capabilityRegistry,
  AiAuditSink? auditSink,
  CallerForegroundProbe? foregroundProbe,
  SupplyTaskPool? taskPool,
}) {
  // M-B：驻留装配点同样补受理链（只填空腿——网关/聊天先装时不拆腿）。
  AiCompleteService.ensureConfigured(
    onDevice: onDeviceCapability,
    quota: supplyQuota,
    capabilityRegistry: capabilityRegistry,
    auditSink: auditSink,
    foregroundProbe: foregroundProbe,
    taskPool: taskPool,
  );
  // 退役清账（2026-11-09）：HostOnDeviceToolExecutor 反向构造已删（其工具面
  // 实例仍由网关装配链承载）。
  Future<Map<String, Object?>?> handle(
    String method,
    Object? params,
    ResolvedCallerIdentity? caller,
  ) async {
    // 退役清账（2026-11-09）：host/onDeviceComplete 响应已删（同 wireSampling）。
    if (method == HostSupplyTaskStatusExecutor.reverseMethodName) {
      return forwardSupplyTaskStatus(
        params,
        callerKeyOverride: caller?.packageName ?? callerKey,
      );
    }
    return null;
  }

  final transport = client.transport;
  if (transport is ReverseSessionTransport) {
    // M-B：驻留场景同款会话钩子（W6-a 驻留缺口教训——goodshare 反向帧经
    // task-consume client 到达，不接线即 result:null）。ai/* 直达受理链，
    // 其余委托 handle()（含未知 method → result:null 既有语义）。
    transport.onServerRequestSessionWithCaller =
        (method, id, params, caller, emit) async {
      final handled = await AiCompleteService.instance.handleAiMethod(
        method: method,
        id: id,
        params: params,
        caller: caller,
        callerKeyFallback: caller.packageName,
        emit: emit,
      );
      if (handled) return;
      try {
        final r = await handle(method, params, caller);
        emit(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': r});
      } on McpRpcException catch (e) {
        emit(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': e.code,
            'message': e.message,
            if (e.data != null) 'data': e.data,
          },
        });
      } catch (e) {
        emit(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': -32603,
            'message': '宿主反向请求处理失败: $e',
          },
        });
      }
    };
  } else if (transport is CallerIdentityTransport) {
    transport.onServerRequestWithCaller =
        (method, params, caller) => handle(method, params, caller);
  } else {
    client.onServerRequest = (method, params) => handle(method, params, null);
  }
}

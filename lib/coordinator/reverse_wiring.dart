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

import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/sampling_engine.dart' show CloudSamplingEngine;
import '../core/errors/mcp_error.dart';
import '../llm/on_device_capability.dart';
import '../mcp/sampling.dart' show SamplingQuota, samplingRequestHandler;
import '../mcp/transport/binder_transport.dart';
import 'caller_death_interrupt.dart';
import 'host_on_device_tool.dart';
import 'supply_quota.dart';
import 'mcp_tool_face.dart';

/// 逐 face 接线 sampling 反向请求（serverKey = serverId）。
///
/// [excludedServerIds]：不供给反向请求的面（网关传 `kHostServerId`——host 面
/// 是宿主自身导出面，不回调宿主推理）。
///
/// **W5 跨 App 转发端侧算力（Binder 路径）**：[onDeviceCapability] 非空时，
/// 同一反向请求通道扩派私有 method **`host/onDeviceComplete`**（Tier 1 契约，
/// params 同导出工具 {instruction, input}）——转发方（同机插件 App）经此用
/// 宿主**端侧**算力（sampling 反向请求走云端引擎，二者并存不互替）。降级
/// 语义与 K22 配额由导出执行器统一承载（`HostOnDeviceToolExecutor`——与
/// `host__on_device_complete` 工具面同源，禁双实现漂移）；失败转 McpRpcException
/// error 帧（message 含原因与「宿主不兜底云端」提示——转发方显式可知红线）。
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
}) {
  // K17 装配接线（幂等单例；两装配点经本共享件同款调用，消第二副本）。
  ensureCallerDeathInterruptWired();
  for (final entry in faces.entries) {
    if (excludedServerIds.contains(entry.key)) continue;
    final sampling = samplingRequestHandler(
      engine: CloudSamplingEngine(engine),
      quota: quota,
      serverKey: entry.key,
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
              );
    entry.value.client.onServerRequest = (method, params) {
      if (method == HostOnDeviceToolExecutor.reverseMethodName) {
        return _forwardOnDeviceComplete(supplyExport!, params);
      }
      onSamplingBegin?.call();
      return sampling(method, params).whenComplete(() => onSamplingEnd?.call());
    };
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
  if (transport is BinderTransport) return transport.packageName;
  return face.serverId;
}

/// host/onDeviceComplete 反向请求处理：转发到导出执行器（K22 配额 + 降级
/// 语义单源——params 序列化后经同一 execute 路径，禁旁路副本）；isError
/// 结果转 McpRpcException(-32000) error 帧（message 原文透传，转发方显式
/// 可知红线）。
Future<Map<String, Object?>?> _forwardOnDeviceComplete(
    HostOnDeviceToolExecutor export, Object? params) async {
  final p = params is Map<String, Object?> ? params : <String, Object?>{};
  final r = await export.execute(AssembledToolCall(
    id: 'rev-host-export',
    name: HostOnDeviceToolExecutor.toolName,
    argumentsJson: jsonEncode(p),
  ));
  if (r.isError) {
    throw McpRpcException(-32000, r.content);
  }
  return {
    'role': 'assistant',
    'model': 'goodhub-on-device',
    'content': {'type': 'text', 'text': r.content},
  };
}

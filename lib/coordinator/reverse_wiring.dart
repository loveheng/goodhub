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

import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/sampling_engine.dart' show CloudSamplingEngine;
import '../mcp/sampling.dart' show SamplingQuota, samplingRequestHandler;
import 'mcp_tool_face.dart';

/// 逐 face 接线 sampling 反向请求（serverKey = serverId）。
///
/// [excludedServerIds]：不供给反向请求的面（网关传 `kHostServerId`——host 面
/// 是宿主自身导出面，不回调宿主推理）。
void wireSampling({
  required Map<String, McpToolFace> faces,
  required CloudLlmEngine engine,
  required SamplingQuota quota,
  Set<String> excludedServerIds = const <String>{},
  void Function()? onSamplingBegin,
  void Function()? onSamplingEnd,
}) {
  for (final entry in faces.entries) {
    if (excludedServerIds.contains(entry.key)) continue;
    final sampling = samplingRequestHandler(
      engine: CloudSamplingEngine(engine),
      quota: quota,
      serverKey: entry.key,
    );
    entry.value.client.onServerRequest = (method, params) {
      onSamplingBegin?.call();
      return sampling(method, params).whenComplete(() => onSamplingEnd?.call());
    };
  }
}

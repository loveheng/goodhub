/// 远程任务来源注册表（ai-capability-export 通用化 2026-11-09）。
///
/// **契约探测**：来源的准入判据 = 插件 `tools/list` 含
/// [McpTaskQueueContract.probeAnchor]（`claim_ai_task`）——即该 server 实现
/// 了远程任务队列契约（ai-app-split.md §3.2–3.4；goodshare 为首个实现）。
/// 宿主 bootstrap 对每个受信任的本地插件跑一次探测，命中即建消费循环；
/// 未命中的插件仍挂通用反向面（`ai/complete` 算力借用——消费端能力与任务
/// 契约正交）。
///
/// **纪律**：本表不认识任何具体包名（goodshare 由契约天然覆盖）；新来源
/// = 实现契约工具集，零宿主改动。
library;

import '../mcp/local_plugin_discovery.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_task_queue.dart';
import 'task_source.dart' show McpTaskQueueSource;

/// 探测结果：null = 未实现任务队列契约（仅普通插件/算力借用方）；
/// 非 null = 可建消费循环的来源适配器。
typedef ResolvedTaskSource = McpTaskQueueSource;

/// 任务来源注册表（进程级单例语义——bootstrap 持有；无状态可直构）。
class TaskSourceRegistry {
  const TaskSourceRegistry();

  /// 契约探测（negotiate → `tools/list` → 锚匹配整体内聚——调用方零协议
  /// 感知）：含探测锚 → 构造以 `info.packageName` 为 serverId 的来源适配器
  ///（K17 身份键同源）。探测失败（RPC 异常/形状异常）= 未命中（禁猜测性放行）。
  Future<ResolvedTaskSource?> resolve(
    LocalPluginInfo info,
    McpClient client,
  ) async {
    await client.negotiate();
    final result = await client.call('tools/list');
    if (result is! Map) return null;
    final tools = result['tools'];
    if (tools is! List) return null;
    final names = <String>{
      for (final t in tools)
        if (t is Map && t['name'] is String) t['name'] as String,
    };
    if (!names.contains(McpTaskQueueContract.probeAnchor)) return null;
    return McpTaskQueueSource(
      McpTaskQueueApi(client),
      serverId: info.packageName,
    );
  }
}

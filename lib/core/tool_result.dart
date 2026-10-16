/// 工具执行结果（arch-hardening ②：自 `coordinator/agent_loop.dart` 下沉）。
///
/// 执行环通用货币——coordinator（AgentLoop/ToolExecutor）、mcp（连接门
/// guardExecute）、gateway（安全管线）三域共用；纯数据无依赖，落 core
/// 使 mcp/gateway 无需反向 import coordinator。
library;

/// 工具执行结果。
class ToolExecutionResult {
  const ToolExecutionResult({required this.content, this.isError = false});

  final String content;
  final bool isError;
}

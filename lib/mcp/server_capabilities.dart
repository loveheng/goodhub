/// Server 能力协商结果与 Tier 2 静态摘要（M2.5-T2）。
/// 契约 SSOT：goodshare 仓 ai-app-split.md §3.6（Tier 分类）+ 本仓
/// architecture.md §14（Polyfill 降级矩阵、静态摘要数据源）。
/// 解析防御口径：字段缺省 = 无该能力 = Polyfill 接管——降级是默认行为，
/// 不抛异常；仅 result 整体非对象才算协议违规。
library;

import '../core/errors/mcp_error.dart';

/// 宿主发起 initialize 所用的协议版本（MCP 2025-06-18）。
const kMcpProtocolVersion = '2025-06-18';

/// initialize 握手结果（MCP 2025-06-18）：capabilities + serverInfo + instructions。
class ServerCapabilities {
  const ServerCapabilities({
    required this.protocolVersion,
    required this.hasTools,
    required this.hasPrompts,
    required this.hasResources,
    this.hasSampling = false,
    this.hasSubscriptions = false,
    this.serverName,
    this.serverVersion,
    this.instructions,
  });

  final String protocolVersion;
  final bool hasTools;
  final bool hasPrompts;
  final bool hasResources;

  /// M3 消费面 gate（ai-app-split.md §3.11）：server 声明 sampling 时宿主
  /// 工具调用强制走流式（反向请求帧需要帧间夹带通道）+ 开放 sampling 消费。
  final bool hasSampling;

  /// M3 订阅消费 gate（§3.10）：server 声明 resources.subscribe 时宿主才建
  /// GET SSE 订阅连接。两者均不入 Tier 判定（§3.6 Tier 1 = prompts+resources 齐）。
  final bool hasSubscriptions;

  final String? serverName;
  final String? serverVersion;
  final String? instructions;

  /// Tier 1 = 接缝契约全量（ai-app-split.md §3.6：prompts+resources 声明齐全）。
  /// progress 不入 capabilities（per-request opt-in，§3.9），不参与判定。
  bool get isTier1 => hasPrompts && hasResources;

  /// Tier 2 = vanilla MCP（仅 tools）——宿主 Polyfill：无 prompts → 无 Skill
  /// 注入；无 resources → 只读工具照常暴露；无 progress → 纯 Loading 态。
  bool get isTier2 => !isTier1;

  factory ServerCapabilities.parse(Object? result) {
    if (result is! Map<String, Object?>) {
      throw const McpProtocolException('initialize result is not an object');
    }
    final caps = result['capabilities'];
    bool has(String key) => caps is Map && caps[key] != null;
    final serverInfo = result['serverInfo'];
    return ServerCapabilities(
      protocolVersion:
          result['protocolVersion'] is String ? result['protocolVersion'] as String : kMcpProtocolVersion,
      hasTools: has('tools'),
      hasPrompts: has('prompts'),
      hasResources: has('resources'),
      serverName:
          serverInfo is Map && serverInfo['name'] is String ? serverInfo['name'] as String : null,
      serverVersion: serverInfo is Map && serverInfo['version'] is String
          ? serverInfo['version'] as String
          : null,
      instructions:
          result['instructions'] is String ? result['instructions'] as String : null,
    );
  }
}

/// Tier 2 静态摘要字符预算硬封顶（architecture §14 C-4：约 150 Tokens，
/// 防不受控 Server 污染常驻 Prompt 预算）。
const kStaticSummaryBudget = 500;

/// Tier 2 首次挂载的静态摘要（architecture §14 六轮评审）：读 tools/list 前
/// 3 个工具 name+description 拼接；超预算机械截断 + 省略号；切片 take(3)
/// 防 Server 工具数 <3 越界；产出恒带「自动生成」标注——防模型把拼凑摘要
/// 当服务端权威声明。Tier 1 Server 不消费本函数（契约注解优先）。
String buildStaticSummary(Iterable<({String name, String description})> tools) {
  final joined = [
    for (final t in tools.take(3))
      '${t.name}: ${t.description.isEmpty ? '（无描述）' : t.description}',
  ].join('；');
  final body = joined.length <= kStaticSummaryBudget
      ? joined
      : '${joined.substring(0, kStaticSummaryBudget)}…';
  return '（自动生成）$body';
}

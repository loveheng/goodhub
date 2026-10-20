/// ToolRouter：多 Server 工具路由（F1.2 命名空间隔离 + F1.9 海关门控）。
///
/// **海关规则（SDK 0.2.0 口径，2026-10-21 更正）**：`tools/list` 条目的
/// `_meta.goodhub.visibility == "shared"` 才收集；**字段缺失 / 形状异常 /
/// 取值未知一律按 `"private"` 兜底**（default-deny），私有坚决不收集。
/// 旧口径 `annotations["x-mcp-export-to-shared"]` **已作废**——它把访问控制
/// 标记塞进 MCP `annotations`（规范定位是 advisory hints）且顶了官方 `x-`
/// 命名空间。`readOnlyHint` 标准注解仅建议值——客户端 L1/L2 权限网关终裁在
/// M2 coordinator，本层只存储不裁决。
///
/// **声明而非访问控制（责任边界）**：SDK 永不因该标记剔除 `tools/list` 条目
/// （目录恒为能力全集）、永不拦截 `tools/call`；过滤是**客户端组织行为**，
/// private 工具在本机链路照常发现与调用，只是不进共享目录 / 不向外部 Agent
/// 暴露。可见性不是安全边界（调用方可信性另由同签名 / 信任白名单把关）。
///
/// ⚠️ **接线状态（2026-10-21）**：生产路由走 `coordinator/tool_router.dart`
/// （多 Server 前缀路由）；海关过滤已接线在**对外暴露面**——
/// `gateway/mcp_gateway_handler.dart` 的 `toolsList()` 只回 shared 工具
/// （F1.9 / SA-Q6 三项前置条件中「服务端打标 ✅ SDK 0.2.0」「缺失即私有 ✅」
/// 已成立）。**本机链路（宿主聊天装配面）不过滤**——未打标服务端（如
/// goodshare）在此口径下全量归 private，过滤即生产工具面归零。
///
/// 本文件 = 海关规则的独立实现与单测面，按 `context/pending-confirm.md`
/// SA-Q6 拍板**保留**（收编进 `coordinator/tool_router.dart` 记为架构债 #9）。
library;

import '../core/errors/mcp_error.dart';
import '../core/tool_visibility.dart';
import 'mcp_client.dart';

/// tools/list 单个工具条目（强类型解析；Schema 以 JSON 值树保留，禁 dynamic 穿总线）。
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.readOnlyHint = false,
    this.visibility = ToolVisibility.private,
  });

  factory McpTool.parse(Map<String, Object?> raw) {
    final name = raw['name'];
    if (name is! String || name.isEmpty) {
      throw const McpProtocolException('tools/list entry missing name');
    }
    // coding-standards §5.6：双下划线仅作命名空间分隔符，工具名内禁用
    if (name.contains('__')) {
      throw McpProtocolException(
          'tool name "$name" must not contain "__" (namespace separator)');
    }
    final description = raw['description'];
    final schema = raw['inputSchema'];
    final annotations = raw['annotations'];
    var readOnly = false;
    if (annotations is Map<String, Object?>) {
      final ro = annotations['readOnlyHint'];
      if (ro is bool) readOnly = ro;
    }
    return McpTool(
      name: name,
      description: description is String ? description : '',
      inputSchema:
          schema is Map<String, Object?> ? Map.unmodifiable(schema) : const {},
      readOnlyHint: readOnly,
      // 可见性走 GoodHub 私有子树 `_meta.goodhub.visibility`（缺失即 private）。
      visibility: parseToolVisibility(raw['_meta']),
    );
  }

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final bool readOnlyHint;

  /// 可见性范围（`_meta.goodhub.visibility`；缺失即私有）。
  final ToolVisibility visibility;
}

class _Routed {
  const _Routed(this.serverId, this.tool);
  final String serverId;
  final McpTool tool;
}

class ToolRouter {
  final Map<String, McpClient> _clients = {};
  final Map<String, _Routed> _registry = {};

  /// 挂载一个 Server：tools/list → 海关过滤 → 命名空间注册。
  /// 未打标工具一律不注册（私有）；全部未打标则该 Server 共享目录为空。
  Future<void> mount(McpClient client, String serverId) async {
    if (serverId.isEmpty || serverId.contains('__')) {
      throw McpProtocolException(
          'invalid server id "$serverId" (non-empty, no "__")');
    }
    final result = await client.call('tools/list');
    final tools = result is Map<String, Object?> ? result['tools'] : null;
    if (tools is! List) {
      throw const McpProtocolException('tools/list result lacks tools list');
    }
    for (final entry in tools) {
      if (entry is! Map<String, Object?>) {
        throw const McpProtocolException('tools/list entry is not an object');
      }
      final tool = McpTool.parse(entry);
      if (tool.visibility != ToolVisibility.shared) continue; // 非 shared = 私有，坚决不收集
      final namespaced = '${serverId}__${tool.name}';
      if (_registry.containsKey(namespaced)) {
        throw McpProtocolException('namespace collision: $namespaced');
      }
      _registry[namespaced] = _Routed(serverId, tool);
    }
    _clients[serverId] = client;
  }

  /// 共享目录（海关过滤后、命名空间化）。
  List<String> get catalog => _registry.keys.toList()..sort();

  McpTool? lookup(String namespaced) => _registry[namespaced]?.tool;

  Future<Object?> call(
    String namespaced, {
    Map<String, Object?> args = const {},
  }) async {
    final routed = _registry[namespaced];
    if (routed == null) {
      throw McpProtocolException('unregistered tool: $namespaced');
    }
    final client = _clients[routed.serverId]!;
    return client.call(routed.tool.name, params: args);
  }

  void unmount(String serverId) {
    _clients.remove(serverId);
    _registry.removeWhere((name, _) => name.startsWith('${serverId}__'));
  }
}

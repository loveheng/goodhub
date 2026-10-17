/// ToolRouter：多 Server 工具路由（F1.2 命名空间隔离 + F1.9 海关门控）。
/// 海关规则（architecture §8）：tools/list annotations 声明 `x-mcp-export-to-shared: true`
/// 才收集；未打标即私有，坚决不收集。`readOnlyHint` 标准注解仅建议值——
/// 客户端 L1/L2 权限网关终裁在 M2 coordinator，本层只存储不裁决。
///
/// ⚠️ **未接线（2026-10-15 对账标注，勿当死代码删除）**：生产路由走
/// `coordinator/tool_router.dart`（多 Server 前缀路由，**不带海关过滤**）；
/// 本文件是 **F1.9（P0 需求）的唯一实现**，当前仅 `test/tool_router_test.dart`
/// 引用。
///
/// **未接线的原因（启用即破坏现状）**：现网服务端（goodshare、本地 Binder
/// 插件）**普遍不下发 annotations**——真机取证见 thirdconnect memory（dummy
/// 全工具因 SDK 不发 annotations 双缺从严落 L2）。一旦启用海关过滤，
/// 未打标工具会被**全部过滤**，生产功能直接归零。
///
/// **启用前置条件（三者齐备才可接线）**：① 服务端普遍打标（`x-mcp-export-to-shared`
/// 或标准 `readOnlyHint`）；② 明确「未打标即私有」的降级口径并通告生态；
/// ③ 接线点 = 装配层（`chat_page._send` 建 face 后）+ 网关对外目录
/// （`mcp_gateway_handler.toolsList`）两处都要过过滤。
///
/// 处置选项见 `context/pending-confirm.md` SA-Q6（保留待接线 / 归档）。
library;

import '../core/errors/mcp_error.dart';
import 'mcp_client.dart';

/// tools/list 单个工具条目（强类型解析；Schema 以 JSON 值树保留，禁 dynamic 穿总线）。
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.readOnlyHint = false,
    this.exportToShared = false,
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
    var export = false;
    if (annotations is Map<String, Object?>) {
      final ro = annotations['readOnlyHint'];
      if (ro is bool) readOnly = ro;
      final ex = annotations['x-mcp-export-to-shared'];
      if (ex is bool) export = ex;
    }
    return McpTool(
      name: name,
      description: description is String ? description : '',
      inputSchema:
          schema is Map<String, Object?> ? Map.unmodifiable(schema) : const {},
      readOnlyHint: readOnly,
      exportToShared: export,
    );
  }

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final bool readOnlyHint;
  final bool exportToShared;
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
      if (!tool.exportToShared) continue; // 未打标 = 私有，坚决不收集
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

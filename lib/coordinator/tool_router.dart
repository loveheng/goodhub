/// ToolRouter——多 Server 前缀隔离路由注册表（M4-T6，F1.2）。
/// 规格 SSOT：architecture.md §1（ToolRouter 命名空间前缀隔离）/§7（JIT 二级
/// 元工具）/§14（Tier 协商）+ M4 施工设计 T6 注记。
///
/// - **不是装饰器**：直接持 `Map<serverId, McpToolFace>`；对外工具名
///   `<serverId>__<toolName>`（coding-standards §5.6：双下划线仅分隔符，各段
///   自身不含 `__`），[execute] 剥前缀路由——face 收裸名，server 侧零感知；
/// - **激活集会话粒度**（§15）：router 实例随会话建；未激活 server 的调用
///   → isError 引导先 `activate_server_tools`（幻觉调用防线 + N2 常驻开销
///   恒定的守门面——未激活工具不进 tools 列表，双保险）；
/// - **serverFor**：前缀名 → 来源 serverId（AgentLoop put 端 `$ref` 句柄
///   来源解析用；宿主本地工具名无前缀返回 null——本地结果不落池语义由调用
///   方维持 M2 引用标记形态）；
/// - 路由目标缺失（server 掉线未从注册表摘除）→ isError 不抛穿执行环。
library;

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';
import 'mcp_tool_face.dart';

/// 前缀分隔符（coding-standards §5.6：双下划线仅作两段分隔符）。
const String kToolNamespaceSep = '__';

/// 拆 `<serverId>__<toolName>`；不合规（无分隔符/空段）返回 null。
({String serverId, String toolName})? parsePrefixedToolName(String name) {
  final i = name.indexOf(kToolNamespaceSep);
  if (i <= 0 || i == name.length - kToolNamespaceSep.length) return null;
  final serverId = name.substring(0, i);
  final toolName = name.substring(i + kToolNamespaceSep.length);
  if (serverId.contains(kToolNamespaceSep) || toolName.contains(kToolNamespaceSep)) {
    return null;
  }
  return (serverId: serverId, toolName: toolName);
}

class ToolRouter implements ToolExecutor {
  ToolRouter({required Map<String, McpToolFace> faces,
      Set<String> privateServerIds = const {}})
      : _faces = Map.of(faces),
        privateServerIds = Set.of(privateServerIds);

  final Map<String, McpToolFace> _faces;

  /// 私有服务 id 集（Provider×Tier 两维，P1-4 / SSOT §1.6）：由装配层按
  /// `ServerEndpoint.tier` 注入；不在集内 = public（缺省公共，沉默即公共面）。
  final Set<String> privateServerIds;

  /// 已激活 server 集（会话粒度——实例随会话建；JIT 元工具写，T6-3 接线）。
  /// 新模型下只收 public 挂载；private 走 [activePrivateServerId] 槽位。
  final Set<String> activatedServers = {};

  /// 单一私有槽位（D-C）：私有+私有互斥由本槽位构造保证——抢占即替换，无需
  /// 额外闸门；null = 当前无激活私有域。public 不进槽位（常驻）。
  String? activePrivateServerId;

  int get serverCount => _faces.length;
  List<String> get serverIds => _faces.keys.toList(growable: false);
  McpToolFace? faceOf(String serverId) => _faces[serverId];

  /// 前缀化工具名（装配层下发 tools 列表与 loadCatalog 用）。
  static String prefixed(String serverId, String toolName) =>
      '$serverId$kToolNamespaceSep$toolName';

  /// 前缀名 → 来源 serverId；宿主本地工具（无前缀）→ null。
  String? serverFor(String prefixedName) =>
      parsePrefixedToolName(prefixedName)?.serverId;

  /// 某服务的前缀化 schema 列表（face.listTools 结果 + 前缀改写；annotations
  /// 原样保留——网关 hint 按 `serverId__tool` 查询）。
  List<CloudToolSchema> schemasFor(String serverId) {
    final face = _faces[serverId];
    if (face == null) return const [];
    return face.cachedSchemas
        .map((s) => CloudToolSchema(
              name: prefixed(serverId, s.name),
              description: s.description,
              parametersSchema: s.parametersSchema,
              annotations: s.annotations,
            ))
        .toList(growable: false);
  }

  /// 全部服务的激活前缀化 schema（JIT 激活后下发面；T6-3 消费）。
  List<CloudToolSchema> activatedSchemas() => [
        for (final id in activatedServers) ...schemasFor(id),
      ];

  /// 工具面三段式确定序（P1-4 / SSOT §7.4 / §8.2）：
  /// `[全部 public 按 (serverId, toolName) 排序] → [单一 active private 尾部]`
  /// ——公共前缀恒定命中缓存，切换私有域只重排尾部块（meta/skill/memory
  /// 固定尾由装配层在 router 之外追加）。
  List<CloudToolSchema> focusedSchemas() {
    final publics = [
      for (final id in _faces.keys
          .where((id) => !privateServerIds.contains(id))
          .toList()
            ..sort())
        ..._sortedSchemasFor(id),
    ];
    final priv = activePrivateServerId;
    if (priv == null || !_faces.containsKey(priv)) return publics;
    return [...publics, ..._sortedSchemasFor(priv)];
  }

  /// 单服务 schema 按 toolName 字典序固定（上游 tools/list 返回序不可控）。
  List<CloudToolSchema> _sortedSchemasFor(String serverId) {
    final list = schemasFor(serverId).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    final parsed = parsePrefixedToolName(call.name);
    if (parsed == null) {
      return ToolExecutionResult(
        content: '工具名 ${call.name} 不含 $kToolNamespaceSep 服务前缀——'
            '服务工具经 get_connected_apps 查看并用 activate_server_tools 激活',
        isError: true,
      );
    }
    final face = _faces[parsed.serverId];
    if (face == null) {
      return ToolExecutionResult(
        content: '服务 ${parsed.serverId} 未挂载（可能离线）——'
            '用 get_connected_apps 查看当前可用服务',
        isError: true,
      );
    }
    if (!privateServerIds.contains(parsed.serverId)) {
      // public 常驻（§1.6）：仅保留激活集守门（挂载即默认全激活）。
      if (!activatedServers.contains(parsed.serverId)) {
        return ToolExecutionResult(
          content: '服务 ${parsed.serverId} 未激活——'
              '先调用 activate_server_tools(server_id: "${parsed.serverId}") '
              '加载其工具，再重试',
          isError: true,
        );
      }
    } else if (activePrivateServerId != parsed.serverId) {
      // 私有槽位门控（D-C）：未占槽 / 被其他私有域抢占 → 引导 use_server。
      final holder = activePrivateServerId;
      return ToolExecutionResult(
        content: holder == null
            ? '私有服务 ${parsed.serverId} 未激活——'
                '用 use_server(server_id: "${parsed.serverId}") 占用私有槽位'
            : '私有槽位当前由 $holder 占用（单一私有域独占），'
                '不可调用 ${parsed.serverId}——'
                '先 use_server(server_id: "${parsed.serverId}") 抢占槽位，'
                '或 use_server(server_id: "all") 清空',
        isError: true,
      );
    }
    final bare = AssembledToolCall(
      id: call.id,
      name: parsed.toolName,
      argumentsJson: call.argumentsJson,
    );
    return face.execute(bare);
  }
}

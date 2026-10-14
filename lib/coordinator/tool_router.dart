/// ToolRouter——多 Server 前缀隔离路由注册表（M4-T6，F1.2）。
/// 规格 SSOT：architecture.md §1（ToolRouter 命名空间前缀隔离）/§7（JIT 二级
/// 元工具）/§14（Tier 协商）+ M4 施工设计 T6 注记。
///
/// - **不是装饰器**：直接持 `Map<serverId, McpToolFace>`；对外工具名
///   `<serverId>__<toolName>`（coding-standards §4：双下划线仅分隔符，各段
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

/// 前缀分隔符（coding-standards §4：双下划线仅作两段分隔符）。
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
  ToolRouter({required Map<String, McpToolFace> faces})
      : _faces = Map.of(faces);

  final Map<String, McpToolFace> _faces;

  /// 已激活 server 集（会话粒度——实例随会话建；JIT 元工具写，T6-3 接线）。
  final Set<String> activatedServers = {};

  /// 聚焦 server（JIT 元工具 `use_server` 写；null = 未聚焦全量）。
  /// 独占语义：聚焦后下发面仅含该 server，execute 拦截其他 server 引导恢复。
  String? focusedServer;

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

  /// 聚焦生效面（T6-3 `use_server`）：聚焦已挂载 server 时仅其 schema，
  /// 否则等同 [activatedSchemas]（聚焦 server 掉线 → 自动回退全量，不空面）。
  List<CloudToolSchema> focusedSchemas() {
    final f = focusedServer;
    if (f == null || !_faces.containsKey(f)) return activatedSchemas();
    return schemasFor(f);
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
    if (!activatedServers.contains(parsed.serverId)) {
      return ToolExecutionResult(
        content: '服务 ${parsed.serverId} 未激活——'
            '先调用 activate_server_tools(server_id: "${parsed.serverId}") '
            '加载其工具，再重试',
        isError: true,
      );
    }
    final focus = focusedServer;
    if (focus != null && parsed.serverId != focus) {
      return ToolExecutionResult(
        content: '当前聚焦服务 $focus（独占模式），'
            '不可调用 ${parsed.serverId} 的工具——'
            '用 use_server(server_id: "all") 恢复全量后再试',
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

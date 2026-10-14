/// JIT 两级发现元工具（M4-T6-3，F1.3）：宿主本地工具，挂执行链最外层
/// （SkillActivation 之前）——拦截 `get_connected_apps` / `activate_server_tools`，
/// 其余透传 inner。规格 SSOT：m4.md §T6 设计注记。
///
/// - `get_connected_apps`：列出已挂载 server（id + 一行摘要）并提示用
///   `activate_server_tools` 激活；
/// - `activate_server_tools(server_id)`：把 server 加入 [ToolRouter.activatedServers]
///   （L1 静默 + 药丸），下一轮 AgentLoop 经 [toolsProvider] 重算 tools 即带上该
///   server 全量 schema；未知 server_id → isError 回填不抛。
/// - `use_server(server_id)`：聚焦（独占）指定服务——聚焦后下发面
///   [ToolRouter.focusedSchemas] 仅含该 server，其余服务工具从列表摘除；
///   传 "all" 恢复全量。聚焦顺带激活该 server（幂等）。
/// 工具名无 server 前缀，由本执行器在最外层拦截，不进 PermissionGateway
/// （即不触发 L2 确认卡）。
library;

import 'dart:convert';

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';
import 'tool_router.dart';

class DiscoveryExecutor implements ToolExecutor {
  DiscoveryExecutor({
    required this.router,
    required this.inner,
    required this.serverSummaries,
    this.onActivation,
  });

  final ToolRouter router;
  final ToolExecutor inner;

  /// serverId → 一行摘要（装配层拼，标注自动生成）。
  final Map<String, String> serverSummaries;

  /// 激活回调（UI 层落 TrackNote 等副作用；null = 无）。
  final void Function(String serverId)? onActivation;

  static const getConnectedApps = 'get_connected_apps';
  static const activateServerTools = 'activate_server_tools';
  static const useServer = 'use_server';

  /// 解除聚焦的保留字（恢复全量工具面，激活集不变）。
  static const useServerAll = 'all';

  /// 常驻元工具声明（随 AgentLoop tools 下发；L1 静默——Gateway 见不到这两个
  /// 名字，由本执行器在最外层拦截）。
  static List<CloudToolSchema> staticSchemas() => [
        CloudToolSchema(
          name: getConnectedApps,
          description: '列出当前已挂载的 MCP 服务（server_id 与一行摘要）。'
              '某服务的工具使用前须先 activate_server_tools(server_id) 激活，'
              '激活后其工具（名带 <server_id>__ 前缀）才进入可用列表。',
          parametersSchema: <String, Object?>{},
        ),
        CloudToolSchema(
          name: activateServerTools,
          description: '激活某服务的全部工具，使其进入可用工具列表'
              '（L1 静默，后续轮次生效）。server_id 取 get_connected_apps 所列。',
          parametersSchema: <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'server_id': <String, Object?>{
                'type': 'string',
                'description': '目标服务 id（get_connected_apps 所列）',
              },
            },
            'required': <String>['server_id'],
          },
        ),
        CloudToolSchema(
          name: useServer,
          description: '聚焦指定服务（独占模式）：聚焦后可用工具列表仅保留'
              '该服务的工具（名带 <server_id>__ 前缀），其余服务工具被摘除，'
              '直接调用会被拦截，直到切换聚焦或恢复全量。聚焦会顺带激活该服务。'
              'server_id 取 get_connected_apps 所列；传 "all" 解除聚焦恢复全量。',
          parametersSchema: <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'server_id': <String, Object?>{
                'type': 'string',
                'description': '目标服务 id；传 "all" 恢复全量工具面',
              },
            },
            'required': <String>['server_id'],
          },
        ),
      ];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    if (call.name == getConnectedApps) return _listApps();
    if (call.name == activateServerTools) return _activate(call);
    if (call.name == useServer) return _useServer(call);
    return inner.execute(call);
  }

  ToolExecutionResult _listApps() {
    if (router.serverIds.isEmpty) {
      return const ToolExecutionResult(
        content: '当前未挂载任何服务（在 ⚙ 配置 MCP 服务端点）。',
      );
    }
    final lines = [
      for (final id in router.serverIds)
        '- $id: ${serverSummaries[id] ?? '(无摘要)'}'
        '${router.activatedServers.contains(id) ? '' : ' ［未激活，需 activate_server_tools］'}',
    ];
    return ToolExecutionResult(content: '已挂载服务：\n${lines.join('\n')}');
  }

  Future<ToolExecutionResult> _activate(AssembledToolCall call) async {
    final Object? args;
    try {
      args = call.argumentsJson.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(call.argumentsJson);
    } on FormatException {
      return const ToolExecutionResult(
        content: 'activate_server_tools 入参 JSON 损坏（请修正后重试）',
        isError: true,
      );
    }
    final serverId =
        args is Map && args['server_id'] is String ? args['server_id'] as String : '';
    if (serverId.isEmpty) {
      return const ToolExecutionResult(
        content: 'activate_server_tools 缺少 server_id 参数',
        isError: true,
      );
    }
    if (!router.serverIds.contains(serverId)) {
      return ToolExecutionResult(
        content: '未知 server_id: $serverId（可用 get_connected_apps 查看）',
        isError: true,
      );
    }
    final already = router.activatedServers.contains(serverId);
    router.activatedServers.add(serverId);
    if (!already) onActivation?.call(serverId);
    final count = router.schemasFor(serverId).length;
    return ToolExecutionResult(
      content: already
          ? '服务 $serverId 已在激活集（$count 个工具）。'
          : '已激活服务 $serverId（$count 个工具）；后续轮次其工具（${serverId}__*）可用。',
    );
  }

  /// `use_server(server_id)`：聚焦独占指定服务；"all" 恢复全量。
  /// 聚焦顺带激活（幂等，不重复触发 onActivation）；未知 id → isError 不抛。
  Future<ToolExecutionResult> _useServer(AssembledToolCall call) async {
    final Object? args;
    try {
      args = call.argumentsJson.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(call.argumentsJson);
    } on FormatException {
      return const ToolExecutionResult(
        content: 'use_server 入参 JSON 损坏（请修正后重试）',
        isError: true,
      );
    }
    final serverId =
        args is Map && args['server_id'] is String ? args['server_id'] as String : '';
    if (serverId.isEmpty) {
      return const ToolExecutionResult(
        content: 'use_server 缺少 server_id 参数（传 "all" 恢复全量）',
        isError: true,
      );
    }
    if (serverId == useServerAll) {
      final restored = router.focusedServer != null;
      router.focusedServer = null;
      return ToolExecutionResult(
        content: restored
            ? '已解除聚焦，恢复全量工具面（激活集不变）。'
            : '当前未聚焦任何服务，工具面已是全量。',
      );
    }
    if (!router.serverIds.contains(serverId)) {
      return ToolExecutionResult(
        content: '未知 server_id: $serverId（可用 get_connected_apps 查看）',
        isError: true,
      );
    }
    // 聚焦顺带激活（幂等）——解除聚焦后该服务仍在激活集，不回退。
    final newlyActivated = router.activatedServers.add(serverId);
    if (newlyActivated) onActivation?.call(serverId);
    router.focusedServer = serverId;
    final count = router.schemasFor(serverId).length;
    return ToolExecutionResult(
      content: '已聚焦服务 $serverId（$count 个工具，独占模式）——'
          '后续轮次仅其工具（${serverId}__*）可用；'
          '用 use_server(server_id: "all") 恢复全量。',
    );
  }
}

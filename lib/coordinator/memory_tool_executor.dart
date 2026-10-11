/// 记忆读写内部工具面（M4-T2）：update_memory / query_memory——D8 三层作用域
/// 的宿主侧消费口。命名与 architecture §1 Server 角色出厂特权工具对齐
/// （FC6 重启时进程内直调要求 handler 与 HTTP 路径共用，本类即 handler 雏形）。
///
/// - **位置纪律：挂在 PermissionGateway 内侧**（… → Gateway → 本类 → Face）——
///   update_memory 是写操作（readOnlyHint false → L2 确认卡，F4.4 记忆类
///   写路径强制 L2），裁决必须先于执行；query_memory 只读（true → L1 静默 +
///   药丸）。gateway.loadCatalog 须包含 [toolSchemas]（裁决依据）；
/// - **写入门槛（D8 + coding-standards §7.1 主动引导）**：update_memory 的
///   description 明示「只记稳定事实、禁记会话临时快照/易变数据」——数据级
///   事实走 resources/read 实时读，记了会过时；
/// - **§7.3 写后必回最新快照**：update_memory 返回落库条目全字段 JSON（非
///   void/成功文案——模型上下文须与库内状态对齐）；query_memory 空命中返回
///   结构化空集（不 isError，非错误）；
/// - **审计（N4）**：自身调用写 ops.log（server='local'）；审计失败 DEGRADE
///   留痕不阻断工具（审计完整性让位业务可用性，禁静默）。透传调用不在此审计
///   （remote 归 McpToolFace 自审计，server=真实 serverId）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../llm/cloud/cloud_llm.dart';
import '../sandbox/memory_store.dart';
import 'agent_loop.dart';

class MemoryToolExecutor implements ToolExecutor {
  MemoryToolExecutor({
    required this.inner,
    required this.store,
    this.serverId = 'goodshare',
  });

  final ToolExecutor inner;
  final MemoryStore store;

  /// 当前装配的服务绑定（与 refServerId/McpToolFace.serverId 同口径；仅作
  /// 上下文标识，单 Server 阶段恒 'goodshare'）。
  final String serverId;

  static const updateToolName = 'update_memory';
  static const queryToolName = 'query_memory';

  static const _clipLimit = 200;

  /// 工具声明（随 AgentLoop tools 下发；PermissionGateway.loadCatalog 须含
  /// 本清单——readOnlyHint 是 L1/L2 裁决的 hint 源，§8 裁决双源）。
  static List<CloudToolSchema> toolSchemas() => [
        CloudToolSchema(
          name: updateToolName,
          description: '把值得长期记住的事实写入宿主记忆沙盒。怎么用才对：'
              '只记稳定事实——用户偏好、对用户纠错的吸取、与某服务交互的教训；'
              '严禁记录会话临时状态与易变数据快照（如「刚修改了某条目」——'
              '数据类信息应让用户经资源实时读取，写入记忆会过时误导）；'
              '同主题多条事实优先合并为一次调用，勿逐条碎写；scope 按事实'
              '归属填：与任何服务无关填 user，专属于某服务填 srv:服务名。',
          parametersSchema: {
            'type': 'object',
            'properties': {
              'content': {
                'type': 'string',
                'description': '一条独立事实（一句话为宜，自含上下文）',
              },
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '可选标签（如 pref / ui / task）',
              },
              'scope': {
                'type': 'string',
                'description':
                    '作用域：user（默认，全局事实）或 srv:服务名（服务专属事实，'
                        '该服务卸载时会随之清除）',
              },
            },
            'required': ['content'],
          },
          annotations: {'readOnlyHint': false},
        ),
        CloudToolSchema(
          name: queryToolName,
          description: '按关键词检索宿主长期记忆（只读）。适用：回忆用户偏好、'
              '既往教训、检索注入预算外被截断的早期记忆。实时数据不要查记忆——'
              '用资源读取拿当前值。',
          parametersSchema: {
            'type': 'object',
            'properties': {
              'q': {
                'type': 'string',
                'description': '关键词（对正文与标签做包含匹配；缺省 = 全部）',
              },
              'scope': {
                'type': 'string',
                'description': '可选过滤：user 或 srv:服务名',
              },
            },
          },
          annotations: {'readOnlyHint': true},
        ),
      ];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    switch (call.name) {
      case updateToolName:
        return _audited(call, () => _update(call));
      case queryToolName:
        return _audited(call, () => _query(call));
      default:
        return inner.execute(call);
    }
  }

  /// 本地记忆工具的审计包装：成功/失败都落 ops.log（server='local'）。
  Future<ToolExecutionResult> _audited(
    AssembledToolCall call,
    Future<ToolExecutionResult> inner_(),
  ) async {
    final result = await inner_();
    try {
      await store.audit(
        server: 'local',
        tool: call.name,
        ok: !result.isError,
        error: result.isError ? _clip(result.content) : null,
      );
    } catch (e) {
      debugPrint('[DEGRADE] memory-tool: ops audit failed: $e');
    }
    return result;
  }

  Future<ToolExecutionResult> _update(AssembledToolCall call) async {
    final args = _parseArgs(call);
    if (args == null) return _badJson(updateToolName);
    final content = args['content'];
    if (content is! String || content.trim().isEmpty) {
      return const ToolExecutionResult(
        content: 'update_memory 缺少非空 content 参数',
        isError: true,
      );
    }
    final tags = <String>{
      if (args['tags'] is List)
        for (final t in args['tags'] as List)
          if (t is String && t.trim().isNotEmpty) t.trim(),
    };
    final scope = args['scope'] is String ? args['scope'] as String : 'user';
    try {
      final entry = await store.remember(content, tags: tags, scope: scope);
      return ToolExecutionResult(
        content: jsonEncode(<String, Object?>{
          'status': 'ok',
          'entry': <String, Object?>{
            'id': ?entry.id,
            'scope': entry.scope,
            'tags': entry.tags.toList(),
            'ts': ?entry.ts,
            'content': entry.content,
          },
        }),
      );
    } on ArgumentError catch (e) {
      // §7.4 错误契约带 hint：scope 形态错误是模型可自纠分支。
      return ToolExecutionResult(
        content: 'update_memory 参数无效: ${e.message}'
            '（scope 须为 user 或 srv:服务名）',
        isError: true,
      );
    }
  }

  Future<ToolExecutionResult> _query(AssembledToolCall call) async {
    final args = _parseArgs(call);
    if (args == null) return _badJson(queryToolName);
    final q = args['q'] is String ? (args['q'] as String).trim().toLowerCase() : '';
    final scope = args['scope'] is String ? args['scope'] as String : null;
    final entries = await store.listMemories();
    final hits = [
      for (final e in entries)
        if (scope == null || e.scope == scope)
          if (q.isEmpty ||
              e.content.toLowerCase().contains(q) ||
              e.tags.any((t) => t.toLowerCase().contains(q)))
            e,
    ];
    return ToolExecutionResult(
      content: jsonEncode(<String, Object?>{
        'status': 'ok',
        'entries': [
          for (final e in hits)
            <String, Object?>{
              'id': ?e.id,
              'scope': e.scope,
              'tags': e.tags.toList(),
              'ts': ?e.ts,
              'content': e.content,
            },
        ],
        if (hits.isEmpty) 'note': '无匹配记忆条目',
      }),
    );
  }

  Map<String, Object?>? _parseArgs(AssembledToolCall call) {
    if (call.argumentsJson.trim().isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(call.argumentsJson);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  ToolExecutionResult _badJson(String toolName) => ToolExecutionResult(
        content: '$toolName 入参 JSON 损坏（请修正后重试）',
        isError: true,
      );

  String _clip(String text) =>
      text.length <= _clipLimit ? text : '${text.substring(0, _clipLimit)}…';
}

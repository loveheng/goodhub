/// goodshare 接缝契约 §3 三工具封装（SSOT：goodshare 仓 docs/design/ai-app-split.md）。
/// claim_ai_task / touch_ai_task / apply_ai_result——M1 闭环任务原语。
library;

import 'dart:convert' as json;

import '../core/errors/mcp_error.dart';
import 'mcp_client.dart';

/// claim_ai_task 返回：
/// 有任务 {status:"claimed", task_id, item_id, task_action, text, ...}
/// 无任务 {status:"idle"}
/// 条目已删/不可见 {status:"not_found", task_id, item_id, task_action, note}
/// ——宿主按 note 指引用 apply 回写收尾（接缝契约 §3.2）
class ClaimedTask {
  const ClaimedTask({
    required this.taskId,
    required this.itemId,
    required this.taskAction,
    this.text = '',
    this.version,
    this.humanTags,
    this.blockKey,
    this.notFoundNote,
  });

  factory ClaimedTask.parse(Object? result) {
    if (result is! Map<String, Object?>) {
      throw const McpProtocolException('claim result is not an object');
    }
    final status = result['status'];
    if (status == 'idle') return idle;
    final taskId = result['task_id'];
    final itemId = result['item_id'];
    final taskAction = result['task_action'];
    if (taskId is! String || itemId is! String || taskAction is! String) {
      throw const McpProtocolException('claim payload violates contract §3.2');
    }
    if (status == 'not_found') {
      final note = result['note'];
      return ClaimedTask(
        taskId: taskId,
        itemId: itemId,
        taskAction: taskAction,
        notFoundNote: note is String ? note : '条目已不可见',
      );
    }
    final text = result['text'];
    final version = result['version'];
    if (text is! String || version is! int) {
      throw const McpProtocolException('claim payload violates contract §3.2');
    }
    final humanTags = result['human_tags'];
    final blockKey = result['block_key'];
    return ClaimedTask(
      taskId: taskId,
      itemId: itemId,
      taskAction: taskAction,
      text: text,
      version: version,
      humanTags: humanTags is List ? humanTags.cast<String>() : null,
      blockKey: blockKey is String ? blockKey : null,
    );
  }

  static const idle = ClaimedTask(taskId: '', itemId: '', taskAction: 'idle');
  bool get isIdle => taskId.isEmpty;

  /// 条目已不可见分支：任务保持 processing，宿主须 apply 回写收尾。
  bool get notFound => notFoundNote != null;

  final String taskId;
  final String itemId;
  final String taskAction;
  final String text;
  final int? version;
  final List<String>? humanTags;
  final String? blockKey;
  final String? notFoundNote;
}

/// apply_ai_result 的写入载荷（契约 §3.4：至少一个产出字段）。
/// 线上参数键用 `id`（goodshare 工具面条目参数惯例；接缝契约 §3.4 已对齐）。
class ApplyPayload {
  const ApplyPayload({
    required this.taskId,
    required this.itemId,
    this.expectedVersion,
    this.summaryMd,
    this.tags,
    this.note,
    this.blockKey,
  });

  final String taskId;
  final String itemId;
  final int? expectedVersion;
  final String? summaryMd;
  final List<String>? tags;
  final String? note;
  final String? blockKey;

  Map<String, Object?> toParams() => <String, Object?>{
        'task_id': taskId,
        'id': itemId,
        if (expectedVersion != null) 'expected_version': expectedVersion,
        if (summaryMd != null) 'summary_md': summaryMd,
        if (tags != null) 'tags': tags,
        if (note != null) 'note': note,
        if (blockKey != null) 'block_key': blockKey,
      };
}

/// 任务循环门面：认领 → 心跳 → 回写。
class GoodshareTaskApi {
  GoodshareTaskApi(this._client);
  final McpClient _client;

  static const serverPrefix = 'goodshare';

  /// MCP 工具调用走 `tools/call` 信封（method 固定，工具名在 params.name）。
  /// 工具名用 goodshare 注册的裸名（如 `claim_ai_task`）——服务端 tools/list
  /// 即裸名（app-split 契约的 `goodshare__` 前缀是宿主侧路由命名空间，不进线上名）。
  Future<Object?> _tool(String name, {Object? params}) => _client.call(
        'tools/call',
        params: {'name': name, 'arguments': params},
      );

  Future<ClaimedTask> claim() async =>
      ClaimedTask.parse(await _tool('claim_ai_task'));

  /// 推理期间每 5s 一次（含模型加载等待期）；30s 无心跳任务被回收。
  Future<void> touch(String taskId) async {
    await _tool('touch_ai_task', params: {'task_id': taskId});
  }

  /// 返回最新条目快照（同 get_item 形状）；version_conflict 由调用方处理重试。
  Future<Object?> apply(ApplyPayload payload) async {
    final params = payload.toParams();
    final hasOutput = payload.summaryMd != null ||
        payload.tags != null ||
        payload.note != null;
    if (!hasOutput) {
      throw const McpProtocolException('apply requires at least one output');
    }
    return _tool('apply_ai_result', params: params);
  }
}

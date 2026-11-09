/// 远程任务队列契约封装（ai-app-split.md §3.2–3.4 / §3.12.4，泛化自
/// GoodshareTaskApi——ai-capability-export「goodshare 独有支持 → 通用支持」
/// 2026-11-09：任何 MCP server 实现本契约工具集（`claim_ai_task` 锚 + 
/// touch/apply/release）即可成为宿主消费来源，goodshare 为首个实现）。
/// claim_ai_task / touch_ai_task / apply_ai_result——M1 闭环任务原语。
library;

import 'dart:convert' as json;

import '../core/errors/mcp_error.dart';
import 'mcp_client.dart';

/// 远程任务队列契约工具名单源（探测锚 = [toolClaim]；禁缝外重抄字面量）。
abstract final class McpTaskQueueContract {
  static const toolClaim = 'claim_ai_task';
  static const toolTouch = 'touch_ai_task';
  static const toolApply = 'apply_ai_result';
  static const toolRelease = 'release_ai_task';

  /// 探测锚集：tools/list 含 [toolClaim] 即视为实现了本契约
  ///（完整性好坏由消费期错误处理兜底——探测只做准入，不做校验轮）。
  static const probeAnchor = toolClaim;
}

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
    // W4 验收钉·协议版本容错：违约时尽力提取回写锚（taskId/itemId）——
    // 非空锚让消费循环能对该任务单次立即回写不兼容终态（禁重试防坏任务
    // 卡死循环）；连锚都提取不到则 null（兜底=超时回收）。
    McpProtocolException violation(String why) {
      String? tid;
      String? iid;
      if (result is Map) {
        final t = result['task_id'];
        final i = result['item_id'];
        if (t is String && t.isNotEmpty) tid = t;
        if (i is String && i.isNotEmpty) iid = i;
      }
      return McpProtocolException(why, taskId: tid, itemId: iid);
    }

    if (result is! Map<String, Object?>) {
      throw violation('claim result is not an object');
    }
    final status = result['status'];
    if (status == 'idle') return idle;
    final taskId = result['task_id'];
    final itemId = result['item_id'];
    final taskAction = result['task_action'];
    if (taskId is! String || itemId is! String || taskAction is! String) {
      throw violation('claim payload violates contract §3.2');
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
      throw violation('claim payload violates contract §3.2');
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
/// 线上参数键用 `id`（来源工具面条目参数惯例；接缝契约 §3.4 已对齐）。
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

/// 任务循环门面：认领 → 心跳 → 回写（远程任务队列契约的 MCP 适配——
/// 泛化自 GoodshareTaskApi，工具契约名不变）。
class McpTaskQueueApi {
  McpTaskQueueApi(this._client);
  final McpClient _client;

  /// 释放底层 client（window-slim P1-D：此前 client 只进本类私有字段，
  /// 调用方无从关闭——TaskLoopService.close 透传至此）。
  void close() => _client.close();

  /// MCP 工具调用走 `tools/call` 信封（method 固定，工具名在 params.name）。
  /// 工具名用来源注册的裸名（如 `claim_ai_task`）——服务端 tools/list
  /// 即裸名（宿主侧 `__` 前缀是路由命名空间，不进线上名）。
  ///
  /// 结果解包（T7 实测修复）：MCP 标准信封 `{content:[{type:'text',text}], isError}`，
  /// 任务载荷 JSON 在首 text 块里——与 McpToolFace 扁平化同口径；
  /// 非 JSON 文本（如 touch 的 ok）原样返回。
  Future<Object?> _tool(String name, {Object? params}) async {
    final result = await _client.call(
      'tools/call',
      params: {'name': name, 'arguments': params},
    );
    if (result is! Map) return result;
    final content = result['content'];
    if (content is! List || content.isEmpty) return result;
    final first = content.first;
    if (first is! Map || first['type'] != 'text' || first['text'] is! String) {
      return result;
    }
    final text = first['text'] as String;
    try {
      return json.jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  Future<ClaimedTask> claim() async =>
      ClaimedTask.parse(await _tool(McpTaskQueueContract.toolClaim));

  /// 推理期间每 5s 一次（含模型加载等待期）；30s 无心跳任务被回收。
  Future<void> touch(String taskId) async {
    await _tool(McpTaskQueueContract.toolTouch, params: {'task_id': taskId});
  }

  /// 放弃认领（ai-app-split.md §3.12.4 Release 原语）：任务回 pending
  /// 立即可再认领。released=false = 任务不在 processing 态。
  Future<bool> release(String taskId) async {
    final r = await _tool(McpTaskQueueContract.toolRelease,
        params: {'task_id': taskId});
    return r is Map && r['released'] == true;
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
    return _tool(McpTaskQueueContract.toolApply, params: params);
  }
}

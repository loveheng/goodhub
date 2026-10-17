/// 任务闭环服务层（仿 goodshare 双入口范式：业务住 service，入口只做薄适配）。
///
/// 双入口对称（同一方法，两个调用方，零双语义）：
/// - **人类入口**：曾由 `ClaimLoopPage`（已归档至 archive/，2026-10-17）手动
///   触发；现人类手动触发入口摘除，仅保留 AI 入口与复用价值；
/// - **AI 入口**：M2 Agent Loop（coordinator）自动触发——同一 `runOnce`，
///   进度经 `onEvent` 回调上报，入口方自行决定渲染或记遥测。
///
/// goodshare 同构参考：`lib/mcp/tools.dart` claim_ai_task handler 只做参数
/// 校验与形状编排，业务在 Repository——本文件即 GoodHub 侧的 Repository 位。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mcp/goodshare_task_api.dart';
import '../mcp/mcp_client.dart';
import '../mcp/server_endpoints.dart';
import 'task_inference.dart';

/// 闭环单步事件（双入口共用的事件流；UI 据此渲染日志，AI loop 据此记遥测）。
sealed class TaskLoopEvent {
  const TaskLoopEvent();
}

class ClaimStarted extends TaskLoopEvent {
  const ClaimStarted();
}

class QueueIdle extends TaskLoopEvent {
  const QueueIdle();
}

class TaskClaimed extends TaskLoopEvent {
  const TaskClaimed(this.taskId, this.taskAction, this.textLength, this.version);
  final String taskId;
  final String taskAction;
  final int textLength;
  final int? version;
}

class HeartbeatSent extends TaskLoopEvent {
  const HeartbeatSent();
}

class Applied extends TaskLoopEvent {
  const Applied(this.taskId, this.snapshotKeys);
  final String taskId;
  final List<String> snapshotKeys;
}

class NotFoundClosed extends TaskLoopEvent {
  const NotFoundClosed(this.taskId, this.note);
  final String taskId;
  final String note;
}

/// 闭环失败（M2 起真实发出：runOnce 捕获全部异常 → 通告 → 原样上抛）。
class LoopFailed extends TaskLoopEvent {
  const LoopFailed(this.error);
  final Object error;
}

/// claim → 心跳 → apply 一次闭环。
/// M2 推理内核 = [TaskInference]（coordinator 层 HybridTaskInference 实现），
/// 双入口与事件流不变（M1 口径：仅替换内核）。
class TaskLoopService {
  TaskLoopService({
    required this.api,
    required this.inference,
    this.onEvent,
    this.heartbeatInterval = const Duration(seconds: 5),
  });

  final GoodshareTaskApi api;
  final TaskInference inference;

  /// 事件回调：人类入口传 UI setState 适配器；AI 入口传遥测收集器。
  /// 可变：懒构造场景下（UI 先建服务、运行前挂回调）允许运行前重挂。
  void Function(TaskLoopEvent event)? onEvent;

  /// 心跳周期（契约 §3.3：推理期间每 5s 一次，含模型加载期；30s 无心跳被回收）。
  final Duration heartbeatInterval;

  void _emit(TaskLoopEvent event) => onEvent?.call(event);

  /// 释放底层 client（window-slim P1-D：buildApi 建的 McpClient 此前无任何
  /// 释放通道，全类无 close；幂等语义由 McpClient.close 统一承诺）。
  void close() => api.close();

  /// 单次闭环。返回是否实际处理了任务（false = idle）。
  /// 任何异常：先发 [LoopFailed] 通告（AI 入口的遥测依赖），再原样上抛。
  Future<bool> runOnce() async {
    try {
      return await _runOnceInner();
    } on Object catch (e) {
      _emit(LoopFailed(e));
      rethrow;
    }
  }

  Future<bool> _runOnceInner() async {
    _emit(const ClaimStarted());
    final task = await api.claim();
    if (task.isIdle) {
      _emit(const QueueIdle());
      return false;
    }
    if (task.notFound) {
      // 条目已删/不可见：任务保持 processing，按 note 指引用 apply 回写收尾
      await api.apply(ApplyPayload(
        taskId: task.taskId,
        itemId: task.itemId,
        note: 'claim not_found 收尾：${task.notFoundNote}',
      ));
      _emit(NotFoundClosed(task.taskId, task.notFoundNote ?? '条目已不可见'));
      return true;
    }
    _emit(TaskClaimed(task.taskId, task.taskAction, task.text.length, task.version));
    await api.touch(task.taskId);
    _emit(const HeartbeatSent());
    final note = await _inferWithHeartbeat(task);
    final snapshot = await api.apply(_payloadFor(task, note));
    _emit(Applied(
      task.taskId,
      snapshot is Map ? snapshot.keys.cast<String>().toList() : const [],
    ));
    return true;
  }

  /// 产出字段按 task_action 分叉（T7 闭环语义修复，接缝契约 §3.4）：
  /// `llm_summarize` 写 summary_md（条目摘要卡数据源——note-only 落不进卡片，
  /// T2 真机实测发现）；`llm_tags` 写合并标签（D2 只增不删：human_tags ∪ 新提取）；
  /// `block_summarize:*` 写 summary_md（goodshare 按 task_action 落块产物，块摘要
  /// 卡数据源）；未知动作兜底 note（处理说明，契约允许的「至少一个产出字段」）。
  ApplyPayload _payloadFor(ClaimedTask task, String output) {
    final action = task.taskAction;
    final base = (
      taskId: task.taskId,
      itemId: task.itemId,
      expectedVersion: task.version,
    );
    if (action == 'llm_summarize') {
      return ApplyPayload(
        taskId: base.taskId,
        itemId: base.itemId,
        expectedVersion: base.expectedVersion,
        summaryMd: output,
      );
    }
    if (action == 'llm_tags') {
      return ApplyPayload(
        taskId: base.taskId,
        itemId: base.itemId,
        expectedVersion: base.expectedVersion,
        tags: _mergeTags(task.humanTags, output),
      );
    }
    if (action.startsWith('block_summarize')) {
      return ApplyPayload(
        taskId: base.taskId,
        itemId: base.itemId,
        expectedVersion: base.expectedVersion,
        summaryMd: output,
        blockKey: task.blockKey,
      );
    }
    return ApplyPayload(
      taskId: base.taskId,
      itemId: base.itemId,
      expectedVersion: base.expectedVersion,
      note: output,
    );
  }

  /// llm_tags 产出解析：模型关键词文本按常见分隔符切分（顿号/逗号/分号/竖线/
  /// 换行），去空去重；与 human_tags 并集（human 在前保序，只增不删——D2）。
  static List<String> _mergeTags(List<String>? humanTags, String output) {
    final existing = humanTags ?? const <String>[];
    final extracted = output
        .split(RegExp(r'[,，、;；|\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !existing.contains(s))
        .toSet();
    return [...existing, ...extracted];
  }

  /// 推理期间心跳（契约 §3.3：每 [heartbeatInterval] 一次，含模型加载期）。
  Future<String> _inferWithHeartbeat(ClaimedTask task) async {
    final timer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(api.touch(task.taskId).catchError((Object e, StackTrace st) {
        // DEGRADE: 心跳失败不中断推理（下个周期重试；最终 apply 的乐观锁兜底状态一致）——只留痕。
        debugPrint('[DEGRADE] task-heartbeat: touch failed: $e');
      }));
    });
    try {
      return await inference.infer(task);
    } finally {
      timer.cancel();
    }
  }
}

/// 断线重连安全的一等入口包装：构造 client 失败（URL 非法）走 McpException
/// 统一错误契约，调用方无需感知 http 层。
TaskLoopService buildApi({
  required String baseUrl,
  String? apiKey,
  required TaskInference inference,
}) {
  // 步 2-3 适配（window-kernel-split，§8.1-9 凭证隔离）：任务侧连接经 ephemeral
  // 端点对象构造——明文键只入内存（ephemeralKey 不参与 toJson/fromJson），
  // 不进 Directory 列表、不参与 store.save()（全量覆写即落盘）；claim→心跳→apply
  // 调度模型不动，不走 mountEndpoint（任务 API 只需原始 client，
  // 多付 negotiate+listTools RPC 无益）；task 侧无记忆/日志写入点，
  // scope 强制任务上下文由推理侧实现承接（现状无写点 = 隔离天然成立）。
  final ep = ServerEndpoint.ephemeral(endpoint: baseUrl, ephemeralKey: apiKey);
  final client = McpClient.http(baseUrl: ep.endpoint, apiKey: ep.ephemeralKey);
  return TaskLoopService(
    api: GoodshareTaskApi(client),
    inference: inference,
  );
}

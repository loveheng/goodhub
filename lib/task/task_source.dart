/// 任务来源抽象（task-capability W4-A 形态 A 多来源接入，2026-11-04）。
///
/// **定位**：任务消费循环（claim → 心跳 → apply）对「来源」的最小契约——
/// 宿主可注册多个任务来源（首个 = goodshare），循环逻辑零双路分支，来源
/// 差异全部收敛在实现类内（工具名 / 前缀 / 信封形状）。
///
/// **serverId 随来源携带**：对账账本（task_consume_ledger）按 [serverId]
/// 分组（既有维度，账本结构零改）；多来源下各来源的自有 id，禁再写死
/// `kGoodsharePackage`（来源可注册集合的分组键）。
///
/// **依赖方向**：接口住 task 层（与 [TaskInference] 同层位——依赖倒置），
/// 实现住 mcp 层（GoodshareTaskApi 等）。实现侧可后续增补放弃认领
/// （Release/Nack）原语（跨仓 §3.12 增量，见 W4-A 施工记录）。
library;

import '../mcp/goodshare_task_api.dart';

/// 任务来源最小契约。
abstract interface class TaskSource {
  /// 来源标识（对账账本分组键；多来源下唯一）。
  String get serverId;

  /// 认领一个任务（无任务 = 抛 NotFound 语义或返回值内 null 形态，
  /// 与实现现状一致）。
  Future<ClaimedTask> claim();

  /// 推理期心跳（每 5s 一次；超时回收语义在来源侧）。
  Future<void> touch(String taskId);

  /// 回写结果，返回最新条目快照。
  Future<Object?> apply(ApplyPayload payload);

  /// 放弃认领（ai-app-split.md §3.12.4 Release 原语）：任务 processing →
  /// pending 立即可再认领，不等 30s 僵尸回收。与毒丸防护（apply failed）
  /// 语义正交：Release = 任务可完成、宿主暂时没算力；failed = 任务不可
  /// 完成。返回是否释放成功（任务不在 processing 态则 false）。
  Future<bool> release(String taskId);

  /// 释放来源持有的底层资源（client / 通道）。
  void close();
}

/// goodshare 来源适配器（首个 TaskSource 实现）：薄委托 [GoodshareTaskApi]
/// ——适配住 task 层（依赖方向 task→mcp 单向，mcp 不反向依赖 task），
/// serverId 随来源携带（与对账账本现行分组键同值——`kGoodsharePackage`
/// `com.zzh.goodshare`，bootstrap 插件识别的 `info.packageName`；双处同值
/// 禁漂移，消费侧禁再写死包名字面量），消费侧
/// （task_loop_service / bootstrap / 账本）只认 [TaskSource] 类型。
class GoodshareTaskSource implements TaskSource {
  GoodshareTaskSource(this._api);

  final GoodshareTaskApi _api;

  @override
  String get serverId => 'com.zzh.goodshare';

  @override
  Future<ClaimedTask> claim() => _api.claim();

  @override
  Future<void> touch(String taskId) => _api.touch(taskId);

  @override
  Future<Object?> apply(ApplyPayload payload) => _api.apply(payload);

  @override
  Future<bool> release(String taskId) => _api.release(taskId);

  @override
  void close() => _api.close();
}

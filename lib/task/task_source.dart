/// 任务来源抽象（task-capability W4-A 形态 A 多来源接入，2026-11-04；
/// ai-capability-export 通用化 2026-11-09：goodshare 独有支持退役——
/// 实现类泛化为来源无关的 [McpTaskQueueSource]，契约探测入注册表）。
///
/// **定位**：任务消费循环（claim → 心跳 → apply）对「来源」的最小契约——
/// 宿主可注册多个任务来源（首个 = goodshare），循环逻辑零双路分支，来源
/// 差异全部收敛在实现类内（工具名 / 前缀 / 信封形状）。
///
/// **serverId 随来源携带**：对账账本（task_consume_ledger）按 [serverId]
/// 分组（既有维度，账本结构零改）；多来源下各来源的自有 id，禁再写死
/// 包名字面量（来源可注册集合的分组键）。
///
/// **依赖方向**：接口住 task 层（与 [TaskInference] 同层位——依赖倒置），
/// 实现住 mcp 层（McpTaskQueueApi 等）。实现侧可后续增补放弃认领
/// （Release/Nack）原语（跨仓 §3.12 增量，见 W4-A 施工记录）。
library;

import '../core/data_source.dart';
import '../mcp/mcp_task_queue.dart';

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

/// 远程任务队列契约的通用适配器（泛化自 GoodshareTaskSource——
/// serverId 构造注入，来源无关）：薄委托 [McpTaskQueueApi]
/// ——适配住 task 层（依赖方向 task→mcp 单向，mcp 不反向依赖 task），
/// 消费侧（task_loop_service / bootstrap / 账本）只认 [TaskSource] 类型。
class McpTaskQueueSource implements TaskSource {
  McpTaskQueueSource(this._api, {required this.serverId});

  final McpTaskQueueApi _api;

  @override
  final String serverId;

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

/// goodshare 来源适配器（**首个 TaskSource 实现**，2026-11-09 退役为过渡
/// 别名）：serverId 固定 [kPrimaryDataSourcePackage]（首个数据面生态成员，
/// P2 字面量单源）。存量调用点渐进迁移；新代码用 [McpTaskQueueSource]
///（serverId 显式注入）。
@Deprecated('泛化为 McpTaskQueueSource（ai-capability-export 通用化 2026-11-09）')
class GoodshareTaskSource extends McpTaskQueueSource {
  GoodshareTaskSource(super.api) : super(serverId: kPrimaryDataSourcePackage);
}

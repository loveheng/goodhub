/// 端侧算力调用方配额（task-capability W5 · 端侧算力调用方配额）。
///
/// **复用形态红线**：频次记账**复用** `SamplingQuota`（mcp/sampling.dart，
/// 反向请求配额池同形态），不新建限流器；并发上限为独立轻量计数（执行槽
/// 占用语义，非限流器）。
///
/// **配额记账事务语义（K22）**：
/// - **并发**：进入执行槽占用（acquire），退出时**无论成败或切云一律释放**
///   （release 恒达——try/finally 收口）；
/// - **频次**：仅在实际占用算力并**开始产出**时计入（[countOutput]——
///   受理段失败（未就绪/PII/配额）不计；宿主资源问题（打断未生效／内存
///   跌破地板／槽位被占）导致的**被动切云不扣调用方配额**（导出面 failFast
///   无切云，天然满足；hybrid 主路径经 `quotaChecker` 同口径）；
/// - **身份维度**：[callerKey] = 调用方身份键（缺省共享池 `host-export`——
///   host 面单来源场景；gateway 侧 per-caller 精细化接线为跟进项）；
/// - **后台调用方冷装载**：不被自动满足——导出面 failFast 未就绪直接失败
///   （懒加载边界 S16 钉），装载仅 `loadExplicit` 显式发起。
library;

import '../mcp/sampling.dart';

/// 调用方配额（频次 + 并发，事务语义收口）。
class SupplyQuota {
  SupplyQuota({
    SamplingQuota? frequency,
    this.maxConcurrent = 2,
    this.callerKey = 'host-export',
  }) : frequency = frequency ?? SamplingQuota();

  /// 频次记账（复用反向请求配额池形态：默认池 20 次/60min）。
  final SamplingQuota frequency;

  /// 并发上限（执行槽占用维度；导出面单执行槽语义下 2 = 主路径 + 1 导出）。
  final int maxConcurrent;

  /// 调用方身份键（缺省共享池；gateway per-caller 精细化接线为跟进项）。
  final String callerKey;

  int _concurrent = 0;

  /// 当前并发占用数（观测面）。
  int get concurrent => _concurrent;

  /// 并发占用：进入执行槽。满员返回 false（拒绝），否则占用 +1。
  ///
  /// 调用方**必须**配对 [release]（try/finally——退出无论成败一律释放）。
  bool acquire() {
    if (_concurrent >= maxConcurrent) return false;
    _concurrent++;
    return true;
  }

  /// 释放执行槽占用（幂等防御：下溢钳零）。
  void release() {
    if (_concurrent > 0) _concurrent--;
  }

  /// 频次计入：**仅在实际占用算力并开始产出时**调用（受理段失败不计）。
  /// 返回建议重试等待时长（null = 计入成功；非 null = 超限，产出作废与否
  /// 由调用方语义决定——导出面在产出前判定，此处实际不会拒绝）。
  Duration? countOutput(DateTime now) =>
      frequency.tryConsume(callerKey, now);

  /// 频次超限预检（产出前判定：只读不消耗——消耗归 [countOutput]）。
  Duration? checkFrequency(DateTime now) => frequency.peek(callerKey, now);
}

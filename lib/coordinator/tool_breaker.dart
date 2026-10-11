/// 两步熔断与步数墙的排查卡契约（M2-T4b，拍板 C1/C3）。
///
/// - **熔断（C1）**：按工具计数——同工具连续 N（默认 2）次执行报错（isError
///   回填与协议异常均计，二者在执行环收敛为 isError）→ 强中止+排查卡；该工具
///   成功/新用户轮次/人工单步重试才重置，**交叉其他工具成功不重置**；用户 L2
///   拒绝（user_rejected，isError=false）天然不计；
/// - **步数墙（§12）**：max_turns 轮耗尽仍要求工具 → 排查卡，「重试」=人工批准
///   放宽上限 +10 续跑（上下文保留，HITL 越过护栏——墙防无人看管的空转，不防人）；
/// - **delegate 为 null（无人值守/AI 入口）**：熔断即抛 InferenceException 强
///   中止、步数墙即终止——保守缺省，严禁静默续跑。
library;

/// 工具熔断报告（排查卡数据源）。
class BreakerReport {
  const BreakerReport({
    required this.toolName,
    required this.consecutiveFailures,
    required this.lastError,
    required this.argumentsJson,
  });

  final String toolName;
  final int consecutiveFailures;

  /// 最近一次 isError 结果原文（排查卡等宽错误摘要区）。
  final String lastError;
  final String argumentsJson;
}

/// 步数墙超限报告。
class StepWallReport {
  const StepWallReport({required this.turnsUsed, required this.limit});

  final int turnsUsed;
  final int limit;
}

/// 熔断排查卡决议（拍板 C3 三操作）。
sealed class BreakerResolution {
  const BreakerResolution();
}

/// 单步重试：重发同一调用（计数重置；再失败重新累积）。
class RetryOnce extends BreakerResolution {
  const RetryOnce();
}

/// 跳过：当前失败调用按 isError 回填，循环继续（模型自行绕行；计数不重置）。
class SkipOnce extends BreakerResolution {
  const SkipOnce();
}

/// 人工接管：挂起等用户口述/粘贴结果，以 isError=false 回填（模型当正常数据用）。
class ManualResult extends BreakerResolution {
  const ManualResult(this.text);

  final String text;
}

/// 排查卡委托（UI T4c 实现；测试注入假件）。
abstract interface class BlockDelegate {
  /// 工具熔断触发。
  Future<BreakerResolution> onBreakerTripped(BreakerReport report);

  /// 步数墙超限。返回 true = 放宽上限 +10 续跑；false = 终止。
  Future<bool> onStepWallReached(StepWallReport report);
}

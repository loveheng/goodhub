/// 执行面链装配器（ToolExecutor 链的**唯一构造入口** · 架构债 #19 根治）。
///
/// **存在的理由（结构根治，非纪律约束）**：链式执行面若由调用点手工逐层包裹，
/// 极易把新层的 `inner` 指向**链上任一段**而非「已装好的整条链」——内层即被
/// 整层丢弃，对外表现为「工具目录可见、调用全败」（实证 2026-10-23：宿主执行链
/// 在资源面在场时丢掉了 status 层，`host__get_host_status` 列得出、调不动）。
/// 本装配器把「折叠方向」固定为**逐层向外**，调用点**无法再表达**「指向链中段」
/// 的错误形状——该类缺陷从此不可表达，而非靠评审盯住。
///
/// **装配语义**：
/// - 层按「**优先级高 → 低**」给出，列表首位 = 最外层 = 最先命中；
/// - 折叠方向固定：末端兜底 → 依次向外包裹 → 返回最外层；
/// - 兜底缺省 = **显式拒绝**（不静默透传，避免未认领工具悄悄跑到别的层）。
///
/// **用法**（层工厂接收「已装好的下一层」，返回本层实例）：
/// ```dart
/// final executor = composeToolExecutorChain([
///   (inner) => DiscoveryExecutor(inner: inner, ...),
///   (inner) => MemoryToolExecutor(inner: inner, store: store),
/// ], fallback: router);
/// ```
///
/// **机械门禁**：链层构造只允许经本装配器（`inner: inner` 形状）；
/// 手写「inner 指向别的变量」的链构造由 `arch-guard.sh` R9 拦截
/// （规则正文见 `docs/project/coding-standards.md` §8.1「链式装配等价性」）。
library;

import '../llm/cloud/cloud_llm.dart';
import 'agent_loop.dart';

/// 链层工厂：接收「已装好的下一层」返回本层实例。
typedef ToolExecutorLayer = ToolExecutor Function(ToolExecutor inner);

/// 兜底执行面（链条末端）：默认**显式拒绝**——所有层都不认领该工具时，
/// 返回可自纠的错误内容，而不是静默透传或抛裸异常。
class RejectingFallbackExecutor implements ToolExecutor {
  const RejectingFallbackExecutor();

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async =>
      ToolExecutionResult(
        content: '工具 ${call.name} 未接入执行面（链末端兜底拒绝）',
        isError: true,
      );
}

/// 按「优先级高 → 低」装配执行面链（ToolExecutor 链的**唯一入口**）。
///
/// - [layers] 每层是「接收 inner、返回本层」的工厂；列表首位 = 最外层 = 最先命中；
/// - [fallback] 链条末端（所有层都不认领时的去处）；缺省 = 显式拒绝。
///
/// **不变式**：给定 N 层，返回链上恰有 N 层——任一层都在链上（早前手工包裹的
/// 形态允许「新层 inner 指向链中段」，内层即被覆盖丢弃，见架构债 #19）。
ToolExecutor composeToolExecutorChain(
  List<ToolExecutorLayer> layers, {
  ToolExecutor? fallback,
}) {
  var inner = fallback ?? const RejectingFallbackExecutor();
  for (final build in layers.reversed) {
    inner = build(inner);
  }
  return inner;
}
